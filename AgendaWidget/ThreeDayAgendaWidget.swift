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
        WidgetDayNavigation.select(day: Date(timeIntervalSince1970: timestamp))
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
        WidgetDayNavigation.page(page)
        WidgetCenter.shared.reloadTimelines(ofKind: threeDayKind)
        return .result()
    }
}

struct ThreeDayProvider: AppIntentTimelineProvider {
    private let base = AgendaProvider(threeDay: true)
    func placeholder(in context: Context) -> AgendaEntry { base.placeholder(in: context) }
    func snapshot(for configuration: ThreeDayConfigurationIntent, in context: Context) async -> AgendaEntry {
        var entry = context.isPreview ? placeholder(in: context) : await base.entry(theme: configuration.theme, sources: configuration.sources, tasks: configuration.tasks, accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: ThreeDayConfigurationIntent, in context: Context) async -> Timeline<AgendaEntry> {
        await base.timeline(theme: configuration.theme, sources: configuration.sources, tasks: configuration.tasks, accent: configuration.accent).styled(configuration.look)
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
    private var look: WidgetLook { entry.look }
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
    /// The day tabs grow with the text size so the weekday and date stay inside the highlight.
    private var tabHeight: CGFloat { (34 * look.textSize.scale).rounded() }

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
        case .event(let item): look.row(!item.allDay && look.showTimes ? 29 : 18)
        case .task(let task): look.row(task.timed && look.showTimes ? 29 : 19)
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

    /// Never end on a section label with none of its rows.
    private static func withoutTrailingLabels(_ count: Int, in lines: [Line], from start: Int) -> Int {
        var count = count
        while count > 1 && lines[start + count - 1].isLabel { count -= 1 }
        return count
    }

    /// The days after the selected one, each under its own heading, to fill space the selected day leaves empty
    /// in the large widget.
    private var laterLines: [Line] {
        let calendar = Calendar.current
        let selected = calendar.startOfDay(for: entry.selectedDay)
        return days.filter { $0 > selected }.flatMap { day -> [Line] in
            let events = WidgetAgendaLayout.items(on: day, from: entry.items).map { Line.event($0) }
            let tasks = entry.showTasks
                ? entry.tasks.filter { !$0.overdue && $0.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false }.map { Line.task($0) } : []
            let rows = events + tasks
            let heading = calendar.isDateInTomorrow(day) ? "TOMORROW" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
            return rows.isEmpty ? [] : [.label(heading, alert: false)] + rows
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let selectedLines = self.lines
            // An empty day keeps its note above the days after it.
            // Below the day tabs (and their 7-point gap) and above the 16-point bar of buttons.
            let room = max(0, geometry.size.height - tabHeight - 22 - (selectedLines.isEmpty ? 20 : 0))
            let selectedMax = WidgetScroll.maxStart(selectedLines.map(height), in: room)
            // In the large widget, when the selected day fits with room to spare, the days after it fill the rest under
            // their own headings. Small and medium widgets show only the selected day, since rows under the
            // highlighted tab read as that day's.
            let large = geometry.size.height > 300
            let lines = large && selectedMax == 0 ? selectedLines + laterLines : selectedLines
            let heights = lines.map(height)
            let maxStart = selectedMax
            let start = min(max(0, entry.dayPage), maxStart)
            let shown = WidgetScroll.visible(heights, from: start, in: room)
            let count = Self.withoutTrailingLabels(shown, in: lines, from: start)
            let step = WidgetScroll.step(visible: count)
            VStack(alignment: .leading, spacing: 0) {
                dayTabs.padding(.bottom, 5)
                if !entry.connected {
                    Text("Open the app to connect calendars and reminders.").font(.caption).foregroundStyle(muted)
                } else {
                    if selectedLines.isEmpty {
                        Text("No items for this day").font(.caption).foregroundStyle(muted).padding(.top, 4).frame(height: 20, alignment: .top)
                    }
                    // By position: a multi-day event can appear under more than one day.
                    ForEach(Array(lines[start..<start + count].enumerated()), id: \.offset) { line($0.element) }
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
                .buttonStyle(.plain).foregroundStyle(muted).frame(height: 16)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(WidgetContentLayout.insets)
        .foregroundStyle(entry.theme.text(colorScheme))
        .overlay(alignment: .bottom) { WidgetUndoButton(record: entry.completionUndo, date: entry.date) }
        .containerBackground(for: .widget) { entry.theme.backgroundView(colorScheme) }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }

    private var dayTabs: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let selected = Calendar.current.isDate(day, inSameDayAs: entry.selectedDay)
                Button(intent: SelectWidgetDayIntent(day: day)) {
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(look.font(10, .semibold))
                        Text(day.formatted(.dateTime.day())).font(look.font(17, .medium, theme: entry.theme == .gallery ? .serif : .default))
                    }
                    .offset(y: DayTabMetrics.offset(weekdaySize: 10, weekdayWeight: .semibold, dateSize: 17, dateWeight: .medium))
                    .frame(maxWidth: .infinity).frame(height: tabHeight)
                    // On a custom background the accent can vanish, so unselected days use the readable text color.
                    .foregroundStyle(selected ? accent.onColor : entry.theme == .custom && !accent.custom ? entry.theme.text(colorScheme) : accent.color)
                    .background(selected ? accent.color : .clear, in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if look.showAddButton {
                Link(destination: URL(string: "lotsofevents://quick-add?day=\(Int(entry.selectedDay.timeIntervalSince1970))")!) {
                    Image(systemName: "plus").font(look.font(12, .medium)).frame(width: 20, height: tabHeight)
                }.foregroundStyle(muted).accessibilityLabel("Add to selected day")
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
            HStack(spacing: 5) {
                if look.showColorBars { RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3, height: item.allDay ? 13 : 23) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                                if let symbol = item.dateSymbol { Image(systemName: symbol).foregroundStyle(item.color) }
                                Text(item.title).lineLimit(1)
                            }.font(look.font(11, .medium))
                    if !item.allDay && look.showTimes {
                        Text(item.widgetTimeLabel).font(look.font(9)).monospacedDigit().lineLimit(1).foregroundStyle(muted)
                    }
                }
                Spacer(minLength: 0)
            }.frame(height: height(line))
        case .task(let task):
            HStack(spacing: 2) {
                Button(intent: CompleteWidgetReminderIntent(task: task)) {
                    Image(systemName: "circle").font(look.font(14)).foregroundStyle(task.color).frame(width: 22, height: taskHeight)
                }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(look.font(11)).lineLimit(1)
                    if task.timed && look.showTimes, let due = task.due {
                        Text(due.formatted(date: .omitted, time: .shortened)).font(look.font(9)).foregroundStyle(muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }.frame(height: height(line))
        }
    }
}
