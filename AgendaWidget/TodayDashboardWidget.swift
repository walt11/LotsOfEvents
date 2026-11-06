import SwiftUI
import WidgetKit

/// The Events + Tasks widget, styled like the app's Today dashboard: today's schedule, then tasks grouped into
/// Overdue, Today, and Anytime, as one list, optionally followed by the days ahead. Widgets can't scroll, so up/down
/// buttons on a scroll rail move it.
struct TodayDashboardWidgetView: View {
    let entry: DashboardEntry
    let size: CGSize
    /// Set by the in-app preview, where there's no widget family in the environment.
    var previewFamily: WidgetFamily? = nil
    private var look: WidgetLook { entry.look }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { previewFamily ?? environmentFamily }

    private var ink: Color { entry.theme.text(scheme) }
    private var muted: Color { entry.theme.secondary(scheme) }
    /// The weekday uses the accent, except on a custom background without a chosen accent, where it may not stand out.
    private var accent: Color {
        let accent = entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent)
        return entry.theme == .custom && !accent.custom ? ink : accent.color
    }
    private var mono: Font.Design { entry.theme == .gallery ? .monospaced : .default }

    private var events: [AgendaItem] { WidgetAgendaLayout.items(on: entry.date, from: entry.items).filter { !$0.reminder } }
    private var overdue: [WidgetTask] { entry.tasks.filter(\.overdue) }
    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date))! }
    private var dueToday: [WidgetTask] { entry.tasks.filter { $0.due.map { $0 < tomorrow } ?? false && !$0.overdue } }
    private var anytime: [WidgetTask] { entry.tasks.filter { $0.due == nil } }

    // Rows are one line each so as much of the day fits as possible; the buttons keep full-size tap areas.
    // Heights follow the widget look's density and text size.
    private static let spacing: CGFloat = 4
    private var headerHeight: CGFloat { look.row(18) }
    private var eventHeight: CGFloat { look.row(16) }
    private var taskHeight: CGFloat { look.row(19) }
    private var labelHeight: CGFloat { look.row(13) }

    var body: some View {
        let lines = self.lines
        // A row that starts mid-section repeats its section's label on top, so reserve room for it.
        let room = max(0, size.height - headerHeight - Self.spacing)
        let heights = lines.map(height)
        let maxStart = WidgetScroll.maxStart(heights, in: room - labelHeight)
        let start = min(max(0, entry.page), maxStart)
        let sticky = start > 0 && !lines[start].isLabel ? lines[start].section : nil
        let shown = WidgetScroll.visible(heights, from: start, in: room - (sticky == nil ? 0 : labelHeight))
        // Never end on a section label with none of its rows.
        let count = shown > 1 && lines[start + shown - 1].isLabel ? shown - 1 : shown
        let step = WidgetScroll.step(visible: count)
        VStack(alignment: .leading, spacing: Self.spacing) {
            header
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    if let sticky { sectionLabel(sticky.title, sticky.alert ? .red : muted) }
                    ForEach(lines[start..<start + count]) { line($0) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if maxStart > 0 {
                    rail(start: start, maxStart: maxStart, step: step, visible: heights[start..<start + count].reduce(0, +), total: heights.reduce(0, +), height: room)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Lines

    /// `day` sections name a date, so they stay even when section labels are hidden.
    private struct Section: Equatable { let title: String; let alert: Bool; var day = false }
    private enum Line: Identifiable {
        case label(Section), event(AgendaItem, Section), task(WidgetTask, Section), note(String, Section)
        var id: String {
            switch self {
            case .label(let section): "label-\(section.title)"
            case .event(let item, _): "event-\(item.id)"
            case .task(let task, _): "task-\(task.id)"
            case .note(_, let section): "note-\(section.title)"
            }
        }
        var section: Section {
            switch self { case .label(let s), .event(_, let s), .task(_, let s), .note(_, let s): s }
        }
        var isLabel: Bool { if case .label = self { true } else { false } }
    }
    private func height(_ line: Line) -> CGFloat {
        switch line {
        case .label: labelHeight
        case .event: eventHeight
        case .task, .note: taskHeight
        }
    }

    /// The whole day as one list: Schedule, then Overdue, Today, and Anytime tasks.
    private var lines: [Line] {
        let all = allLines
        return look.showSectionLabels ? all : all.filter { if case .label(let section) = $0 { section.day } else { true } }
    }
    private var allLines: [Line] {
        let schedule = Section(title: "SCHEDULE", alert: false)
        var lines: [Line] = [.label(schedule)]
        if !entry.calendarAccess { lines.append(.note("Connect calendars in the app.", schedule)) }
        else if events.isEmpty { lines.append(.note("No events today", schedule)) }
        else { lines += events.map { .event($0, schedule) } }

        let tasks = Section(title: "TASKS", alert: false)
        let problem = !entry.reminderAccess ? "Connect Reminders in the app." : !entry.hasLists ? "Choose reminder lists in the app."
            : overdue.isEmpty && dueToday.isEmpty && anytime.isEmpty ? "All caught up" : nil
        // A note in place of today's tasks still leaves room for the days ahead.
        if let problem { return lines + [.label(tasks), .note(problem, tasks)] + upcomingLines }
        let groups: [(Section, [WidgetTask])] = [(Section(title: "OVERDUE", alert: true), overdue),
                                                 (Section(title: "TODAY", alert: false), dueToday),
                                                 (Section(title: "ANYTIME", alert: false), anytime)]
        for (section, tasks) in groups where !tasks.isEmpty {
            lines.append(.label(section))
            lines += tasks.map { .task($0, section) }
        }
        return lines + upcomingLines
    }

    /// Each later day's events and the reminders due that day, skipping empty days.
    private var upcomingLines: [Line] {
        guard entry.days > 1 else { return [] }
        let calendar = Calendar.current
        let later = (1..<entry.days).flatMap { offset -> [Line] in
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: entry.date))!
            let section = Section(title: offset == 1 ? "TOMORROW" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased(), alert: false, day: true)
            let dayEvents = entry.calendarAccess ? WidgetAgendaLayout.byDay(entry.items, start: day, days: 1).filter { !$0.reminder } : []
            let dayTasks = entry.tasks.filter { $0.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
            if dayEvents.isEmpty && dayTasks.isEmpty { return [] }
            return [.label(section)] + dayEvents.map { .event($0, section) } + dayTasks.map { .task($0, section) }
        }
        let upcoming = Section(title: "UPCOMING", alert: false)
        return later.isEmpty ? [.label(upcoming), .note("Nothing else this week", upcoming)] : later
    }

    @ViewBuilder private func line(_ line: Line) -> some View {
        switch line {
        case .label(let section): sectionLabel(section.title, section.alert ? .red : muted)
        case .event(let item, _): eventRow(item)
        case .task(let task, _): taskRow(task)
        case .note(let text, _): Text(text).font(look.font(11)).foregroundStyle(muted).frame(height: taskHeight, alignment: .leading)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(entry.date.formatted(.dateTime.weekday(family == .systemSmall ? .abbreviated : .wide)))
                .font(look.font(14, .semibold, theme: entry.theme == .gallery ? .serif : .default)).foregroundStyle(accent)
            Text(entry.date.formatted(.dateTime.month(.abbreviated).day())).font(look.font(11)).foregroundStyle(muted)
            Spacer(minLength: 0)
            if look.showAddButton {
                Link(destination: URL(string: "lotsofevents://quick-add")!) {
                    Image(systemName: "plus").font(look.font(13, .medium)).frame(width: 28, height: headerHeight)
                }.accessibilityLabel("Quick add")
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(height: headerHeight)
    }

    /// Up and down buttons with a thumb between them showing where the visible rows sit in the whole list.
    private func rail(start: Int, maxStart: Int, step: Int, visible: CGFloat, total: CGFloat, height: CGFloat) -> some View {
        let button: CGFloat = 24
        let track = max(0, height - button * 2)
        let thumb = max(14, track * min(1, visible / max(total, 1)))
        let offset = (track - thumb) * CGFloat(start) / CGFloat(max(maxStart, 1))
        return VStack(spacing: 0) {
            scrollButton("chevron.up", to: max(0, start - step), enabled: start > 0, label: "Scroll up")
            ZStack(alignment: .top) {
                Capsule().fill(ink.opacity(0.08)).frame(width: 3)
                Capsule().fill(ink.opacity(0.35)).frame(width: 3, height: thumb).offset(y: offset)
            }
            .frame(height: track)
            scrollButton("chevron.down", to: min(maxStart, start + step), enabled: start < maxStart, label: "Scroll down")
        }
        .frame(width: 22)
    }
    private func scrollButton(_ symbol: String, to offset: Int, enabled: Bool, label: String) -> some View {
        Button(intent: DashboardPageIntent(kind: .split, page: offset)) {
            Image(systemName: symbol).font(look.font(11, .semibold)).frame(width: 22, height: 24)
                .background(ink.opacity(enabled ? 0.08 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? ink : muted.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func eventRow(_ item: AgendaItem) -> some View {
        let past = !item.allDay && (item.endDate ?? item.date) <= entry.date
        return HStack(spacing: 5) {
            if look.showColorBars { RoundedRectangle(cornerRadius: 1.5).fill(item.color).frame(width: 3, height: 12) }
            HStack(spacing: 3) {
                                if let symbol = item.dateSymbol { Image(systemName: symbol).foregroundStyle(item.color) }
                                Text(item.title).lineLimit(1)
                            }.font(look.font(11, .medium))
            Spacer(minLength: 2)
            if !item.allDay && look.showTimes { Text(item.widgetStartLabel).font(look.font(9)).monospacedDigit().foregroundStyle(muted).lineLimit(1) }
        }
        .frame(height: eventHeight)
        .opacity(past ? 0.45 : 1)
    }

    private func taskRow(_ task: WidgetTask) -> some View {
        HStack(spacing: 2) {
            Button(intent: CompleteWidgetReminderIntent(task: task)) {
                Image(systemName: "circle").font(look.font(13)).foregroundStyle(task.color).frame(width: 20, height: taskHeight)
            }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
            Text(task.title).font(look.font(11)).lineLimit(1)
            Spacer(minLength: 2)
            // The group label already says Overdue; the time still helps for tasks due later today.
            if task.timed && !task.overdue && look.showTimes, let label = task.trailingLabel {
                Text(label).font(look.font(9)).monospacedDigit().foregroundStyle(muted).lineLimit(1)
            }
        }.frame(height: taskHeight)
    }

    private func sectionLabel(_ title: String, _ color: Color) -> some View {
        Text(title).font(look.font(8, .semibold, theme: mono)).foregroundStyle(color)
            .frame(height: labelHeight, alignment: .bottomLeading)
    }
}
