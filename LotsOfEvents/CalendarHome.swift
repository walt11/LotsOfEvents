import SwiftUI
import EventKit

/// The Calendar tab's views, in the order of its chip bar. A running list of upcoming days is the Agenda tab's job.
enum CalendarDisplay: String, CaseIterable {
    case year = "Year", month = "Month", week = "Week", threeDay = "3 Day", day = "Day"
    var isTimeline: Bool { self == .week || self == .threeDay || self == .day }
}

enum CalendarDates {
    static func swipeDirection(horizontal: CGFloat, vertical: CGFloat) -> Int? {
        guard abs(horizontal) >= 50, abs(horizontal) > abs(vertical) * 1.5 else { return nil }
        return horizontal < 0 ? 1 : -1
    }

    static func monthDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .month, for: date)!.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: start)!
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
    /// Whole weeks needed by this month, without a permanently reserved sixth row.
    static func compactMonthDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let grid = monthDays(containing: date, calendar: calendar)
        let last = grid.lastIndex { calendar.isDate($0, equalTo: date, toGranularity: .month) }!
        return Array(grid.prefix(((last / 7) + 1) * 7))
    }
    static func dayRange(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    static func overlaps(start: Date, end: Date, day: Date, calendar: Calendar = .current) -> Bool {
        let range = dayRange(day, calendar: calendar)
        return start < range.end && (end > range.start || (start == end && start >= range.start))
    }
    /// Where a drag on the timeline drops an event: whole days across (Week view), then the new start rounded to the
    /// nearest quarter hour on the clock, so an event that started at 9:10 can land exactly on 10:00.
    static func dragTarget(start: Date, translation: CGSize, hourHeight: CGFloat, columnWidth: CGFloat?, calendar: Calendar = .current) -> Date {
        let days = columnWidth.map { $0 > 0 ? Int((translation.width / $0).rounded()) : 0 } ?? 0
        let shift = Double(translation.height / hourHeight * 60)
        // Picking an event up without really moving it leaves it where it was, even off the grid.
        if days == 0 && abs(shift) < 7.5 { return start }
        let day = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let parts = calendar.dateComponents([.hour, .minute], from: day)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + shift
        // Stay within the day the event lands on.
        let snapped = min(24 * 60 - 15, max(0, Int((minutes / 15).rounded()) * 15))
        return calendar.date(bySettingHour: snapped / 60, minute: snapped % 60, second: 0, of: day) ?? day
    }
    /// Where dragging an event's bottom edge leaves its end: the nearest quarter hour on the clock, at least 15 minutes after it starts.
    static func resizeTarget(start: Date, end: Date, translation: CGFloat, hourHeight: CGFloat, calendar: Calendar = .current) -> Date {
        let raw = end.addingTimeInterval(Double(translation / hourHeight) * 3600)
        return max(quarterHour(raw, calendar: calendar), start.addingTimeInterval(900))
    }
    /// The quarter hour nearest `date` (or the next one, with `up`).
    static func quarterHour(_ date: Date, calendar: Calendar = .current, up: Bool = false) -> Date {
        let day = calendar.startOfDay(for: date)
        let minutes = date.timeIntervalSince(day) / 60
        let steps = up ? (minutes / 15).rounded(.up) : (minutes / 15).rounded()
        return calendar.date(byAdding: .minute, value: Int(steps) * 15, to: day) ?? date
    }
    /// The range swept by touching and holding an empty part of the timeline, then dragging: from the quarter hour
    /// nearest the first touch to the one nearest the finger, at least 15 minutes, in either direction.
    static func sweep(day: Date, from startY: CGFloat, to endY: CGFloat, hourHeight: CGFloat, calendar: Calendar = .current) -> DateInterval {
        func time(_ y: CGFloat) -> Date {
            let minutes = max(0, min(24 * 60, Double(y / hourHeight) * 60))
            let rounded = Int((minutes / 15).rounded()) * 15
            if rounded == 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))! }
            return calendar.date(bySettingHour: rounded / 60, minute: rounded % 60, second: 0, of: day)!
        }
        let start = time(min(startY, endY))
        return DateInterval(start: start, end: max(time(max(startY, endY)), start.addingTimeInterval(900)))
    }
    /// Side-by-side layout for overlapping spans: each gets a column, plus the column count of its overlap group.
    static func columns(_ spans: [DateInterval]) -> [(column: Int, count: Int)] {
        let order = spans.indices.sorted { spans[$0].start != spans[$1].start ? spans[$0].start < spans[$1].start : spans[$0].end > spans[$1].end }
        var result = Array(repeating: (column: 0, count: 1), count: spans.count)
        var group: [Int] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func closeGroup() {
            for index in group { result[index].count = columnEnds.count }
            group = []
            columnEnds = []
        }
        for index in order {
            let span = spans[index]
            if span.start >= groupEnd { closeGroup() }
            if let free = columnEnds.firstIndex(where: { $0 <= span.start }) {
                columnEnds[free] = span.end
                result[index].column = free
            } else {
                columnEnds.append(span.end)
                result[index].column = columnEnds.count - 1
            }
            group.append(index)
            groupEnd = max(groupEnd, span.end)
        }
        closeGroup()
        return result
    }
}

struct CalendarHome: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Shown inside the Mac window, whose own header switches views, moves between dates, and holds search,
    /// so the chips, date row, and bar are left out.
    var embedded = false
    // Kept on the model so a theme change, which rebuilds the views, doesn't jump back to today.
    private var date: Date {
        get { model.calendarDate }
        nonmutating set { model.calendarDate = newValue }
    }
    private var mode: CalendarDisplay {
        get { model.calendarMode }
        nonmutating set { model.calendarMode = newValue }
    }
    @State private var events: [EKEvent] = []
    /// Worked out when the data changes rather than once per cell on every draw.
    @State private var eventsByDay: [Date: [EKEvent]] = [:]
    @State private var tasksByDay: [Date: [EKReminder]] = [:]
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var gridWidth: CGFloat = 0
    /// The event being dragged on the timeline: the start it would drop at, or with `resize`, its new end.
    @State private var drag: (key: String, target: Date, resize: Bool)?
    /// The range being swept out on an empty part of the timeline for a new event, and its column.
    @State private var sweep: (column: Int, range: DateInterval)?
    /// Pinch the timeline to zoom; remembered between launches.
    @AppStorage("timelineHourHeight", store: Preferences.defaults) private var zoom = 52.0
    @State private var zoomBase: Double?
    /// The timeline's scroll position, and how far down the day it is, so zooming keeps the same hours in view.
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var scrollFraction: CGFloat = 0
    @AppStorage("showWeekNumbers", store: Preferences.defaults) private var weekNumbers = false
    /// An optional second time zone, shown beside the hours on the timeline.
    @AppStorage("secondTimeZone", store: Preferences.defaults) private var secondZoneID = ""
    @State private var datePicker = false
    private var calendar: Calendar { .current }
    private var days: [Date] {
        switch mode {
        case .month: return CalendarDates.compactMonthDays(containing: date)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .threeDay: return (0..<3).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: date)) }
        case .day: return [calendar.startOfDay(for: date)]
        case .year:
            let start = calendar.dateInterval(of: .year, for: date)!.start
            let count = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
            return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !embedded {
                    navigation
                }
                if !model.calendarAccess && !model.reminderAccess && !ContactDates.enabled {
                    AccessCard(title: "Your calendars, together", description: "Connect Apple Calendar to browse and manage events from your synced accounts.") { Task { await model.request(.event) } }
                } else {
                    if mode == .year { yearGrid }
                    else if mode.isTimeline { timeline(days) }
                    else {
                        if mode == .month { monthGrid }
                        agendaList
                    }
                }
            }
            // One background for the controls and the content below them.
            .background(GalleryPalette.paper)
            .navigationTitle("Calendar")
            .galleryTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .tabToolbar(model: model, today: { date = .now }) {
                HStack(spacing: 12) {
                    Menu {
                        Picker("Calendar view", selection: $model.calendarMode) {
                            ForEach(CalendarDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label(mode.rawValue, systemImage: "chevron.down").font(.subheadline.weight(.semibold)) }
                    .accessibilityLabel("Calendar view, \(mode.rawValue)")
                    Button("Weekly Planner", systemImage: "calendar.badge.clock") { model.sheet = .weeklyPlanner }.labelStyle(.iconOnly)
                    CalendarSetsMenu(model: model)
                }
            }
            .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
            .tint(accent)
            .onAppear(perform: reload)
            .onChange(of: date) { _, _ in reload() }
            .onChange(of: mode) { _, _ in reload() }
            .onChange(of: model.calendarReturnToToday) { _, _ in date = .now }
            .onChange(of: model.generation) { _, _ in reload() }
            .sheet(isPresented: $datePicker) {
                // Month and Year jump by month or year; the day-based views pick a day.
                if mode == .month || mode == .year {
                    MonthYearPicker(date: $model.calendarDate, yearsOnly: mode == .year)
                } else {
                    DayPicker(date: $model.calendarDate)
                }
            }
        }
    }
    private var newEventDate: Date {
        calendar.isDateInToday(date) ? Date.now.roundedUpToHalfHour() : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
    }
    private var navigation: some View {
        HStack {
            Button("Previous \(mode.rawValue.lowercased())", systemImage: "chevron.left") { shift(-1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
            Spacer()
            Button { datePicker = true } label: {
                Text(rangeTitle).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                if weekNumbers && mode != .year {
                    Text("W\(calendar.component(.weekOfYear, from: date))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption)
            }.foregroundStyle(.primary)
            Spacer()
            Button("Next \(mode.rawValue.lowercased())", systemImage: "chevron.right") { shift(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.padding(.horizontal, 8)
    }
    private var rangeTitle: String {
        switch mode {
        case .day: return date.formatted(.dateTime.month().day().year())
        case .month: return date.formatted(.dateTime.month(.wide).year())
        case .year: return date.formatted(.dateTime.year())
        case .week, .threeDay: return (days.first!..<days.last!).formatted(.interval.month(.abbreviated).day().year())
        }
    }
    private var monthGrid: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                if weekNumbers { Text("W").font(.caption2).foregroundStyle(.tertiary).frame(width: 22) }
                ForEach(0..<7) { index in Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 2) {
                    if weekNumbers {
                        Text("\(calendar.component(.weekOfYear, from: week[0]))").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 22).accessibilityLabel("Week \(calendar.component(.weekOfYear, from: week[0]))")
                    }
                    ForEach(week, id: \.self) { day in monthCell(day) }
                }
            }
        }.padding(8).gallerySurface(radius: 18).padding(.horizontal, 16).padding(.bottom, 2)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    // Only deliberate horizontal swipes page the month; taps and vertical drags stay available.
                    guard abs(horizontal) >= 50, abs(horizontal) > abs(vertical) * 1.5 else { return }
                    withAnimation(.snappy) { shift(horizontal < 0 ? 1 : -1) }
                }
        )
    }
    private func monthCell(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let dayEvents = eventsOn(day)
        let tasks = tasksOn(day)
        return Button { date = day } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day())).font(.system(.subheadline, design: .rounded, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? _accent.contrastingText : calendar.isDateInToday(day) ? accent : Color.primary)
                HStack(spacing: 2) {
                    ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        Capsule().fill(selected ? _accent.contrastingText : event.calendarColor).frame(width: 6, height: 3)
                    }
                    if let task = tasks.first {
                        Circle().stroke(selected ? _accent.contrastingText : task.calendarColor, lineWidth: 1.5).frame(width: 5, height: 5)
                    }
                    if dayEvents.count + tasks.count > 3 {
                        Text("+").font(.caption2).foregroundStyle(selected ? _accent.contrastingText : .secondary)
                    }
                }.frame(height: 8)
            }
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 58 : 44)
            .background(selected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .opacity(calendar.isDate(day, equalTo: date, toGranularity: .month) ? 1 : 0.4)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(dayEvents.count) events, \(tasks.count) tasks")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .dropDestination(for: String.self) { payloads, _ in model.dropTasks(payloads, on: day) }
    }
    /// Twelve small months; days with events are tinted, and tapping a month opens it.
    private var yearGrid: some View {
        let busy = Set(tasksByDay.keys).union(Set(events.flatMap { event -> [Date] in
            var day = calendar.startOfDay(for: event.startDate)
            var result: [Date] = []
            // Multi-day events tint each day they cover, up to a month.
            while day < event.endDate && result.count < 31 { result.append(day); day = calendar.date(byAdding: .day, value: 1, to: day)! }
            return result.isEmpty ? [calendar.startOfDay(for: event.startDate)] : result
        }))
        let year = calendar.dateInterval(of: .year, for: date)!.start
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(0..<12, id: \.self) { offset in
                    let month = calendar.date(byAdding: .month, value: offset, to: year)!
                    Button {
                        date = month
                        withAnimation(.snappy) { mode = .month }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(month.formatted(.dateTime.month(.wide)))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(calendar.isDate(month, equalTo: .now, toGranularity: .month) ? accent : .primary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                                ForEach(0..<7, id: \.self) { index in
                                    Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
                                }
                                ForEach(CalendarDates.monthDays(containing: month), id: \.self) { day in
                                    let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                                    let today = calendar.isDateInToday(day)
                                    Text(inMonth ? day.formatted(.dateTime.day()) : "")
                                        .font(.system(size: 10, weight: today ? .bold : .regular).monospacedDigit())
                                        .foregroundStyle(today ? _accent.contrastingText : .primary)
                                        .frame(width: 14, height: 14)
                                        .background {
                                            if inMonth && today { Circle().fill(accent) }
                                            else if inMonth && busy.contains(day) { Circle().fill(accent.opacity(0.22)) }
                                        }
                                }
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .gallerySurface(radius: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(month.formatted(.dateTime.month(.wide).year()))
                    .accessibilityHint("Opens this month")
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Label("Tinted days have events", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary).padding(.bottom)
        }
    }
    /// The chosen day's events under the month grid, or what's coming up when it's empty.
    private var agendaList: some View {
        let day = calendar.startOfDay(for: date)
        let dayEvents = eventsOn(day)
        let tasks = tasksOn(day)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button("Previous day", systemImage: "chevron.left") { shiftDay(-1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(GalleryPalette.ink).lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Button("Next day", systemImage: "chevron.right") { shiftDay(1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                Spacer(minLength: 0)
            }.buttonStyle(.plain).foregroundStyle(accent).padding(.horizontal, 16)
            List {
                if dayEvents.isEmpty && tasks.isEmpty {
                    let upcoming = comingUp(after: day)
                    Section {
                        Label("Nothing scheduled", systemImage: "moon.zzz")
                            .font(.subheadline).foregroundStyle(GalleryPalette.muted).listRowBackground(Color.clear)
                    }
                    if !upcoming.isEmpty {
                        Section {
                            ForEach(upcoming, id: \.self) { event in eventRow(event, showDate: true).padding(.horizontal, 4) }
                        } header: { SectionHeader(title: "Coming up") }
                    }
                } else {
                    let conflicts = Conflicts.ids(events: dayEvents, key: dragKey)
                    if dayEvents.contains(where: { $0.contactDateID != nil }) {
                        CompactContactDates(events: dayEvents, model: model)
                            .galleryRow()
                            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 6, trailing: 0))
                    }
                    ForEach(dayEvents.filter { $0.contactDateID == nil }, id: \.self) { event in eventRow(event, conflict: conflicts.contains(dragKey(event))).padding(.horizontal, 4) }
                }
                if !tasks.isEmpty {
                    SectionHeader(title: "Tasks")
                        .accessibilityAddTraits(.isHeader)
                        .galleryRow()
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 0, trailing: 20))
                        .environment(\.defaultMinListRowHeight, 26)
                    ForEach(tasks, id: \.calendarItemIdentifier) { task in
                        taskRow(task).galleryRow()
                            .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
                    }
                }
            }
            .id(day)
            // Only the contact card uses the full grid width; ordinary rows keep their inset.
            .listStyle(.insetGrouped)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .listSectionSpacing(10)
            .contentMargins(.top, 0, for: .scrollContent)
            .appRowHeight(44)
            .refreshable { await model.refresh() }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            if let direction = CalendarDates.swipeDirection(horizontal: value.translation.width, vertical: value.translation.height) {
                shiftDay(direction)
            }
        })
        .accessibilityAction(named: "Previous day") { shiftDay(-1) }
        .accessibilityAction(named: "Next day") { shiftDay(1) }
    }
    private func shiftDay(_ direction: Int) {
        withAnimation(.snappy) {
            date = calendar.date(byAdding: .day, value: direction, to: date) ?? date
        }
    }
    /// The next few events after `day`, looking two months ahead so it doesn't run dry at the end of a month.
    private func comingUp(after day: Date) -> [EKEvent] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        let horizon = calendar.date(byAdding: .day, value: 60, to: end)!
        return Array(model.events(in: DateInterval(start: end, end: horizon)).filter { $0.startDate >= end }.prefix(3))
    }
    private var hourHeight: CGFloat { CGFloat(zoom) }
    private var secondZone: TimeZone? { secondZoneID.isEmpty ? nil : TimeZone(identifier: secondZoneID) }
    /// Wider when a second time zone's hours sit beside the local ones.
    private var gutter: CGFloat { secondZone == nil ? 50 : 84 }
    /// Hours since midnight on the calendar, so blocks line up with the hour grid on DST days too.
    private func hourOffset(_ time: Date, dayStart: Date) -> CGFloat {
        guard time > dayStart else { return 0 }
        guard calendar.isDate(time, inSameDayAs: dayStart) else { return hourHeight * 24 }
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return (CGFloat(parts.hour ?? 0) + CGFloat(parts.minute ?? 0) / 60) * hourHeight
    }
    /// One day's events prepared for the timeline.
    private struct DayColumn {
        let day: Date
        let allDay: [EKEvent]
        let timed: [EKEvent]
        let spans: [DateInterval]
        let layout: [(column: Int, count: Int)]
    }
    private func dayColumn(_ day: Date) -> DayColumn {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let events = eventsOn(day)
        let timed = events.filter { !$0.isAllDay }
        // Short and zero-length events still take 15 minutes, so they stay readable and tappable.
        let spans = timed.map { event -> DateInterval in
            let begin = max(event.startDate, start)
            return DateInterval(start: begin, end: max(begin, min(max(event.endDate, begin.addingTimeInterval(900)), end)))
        }
        return DayColumn(day: start, allDay: events.filter(\.isAllDay), timed: timed, spans: spans, layout: CalendarDates.columns(spans))
    }
    private func hourLabel(_ hour: Int) -> String {
        (calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date).formatted(.dateTime.hour())
    }
    private func addEvent(hour: Int, on day: Date) {
        model.sheet = .newEvent(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day)
    }
    /// The Day view (one column) and Week view (seven columns) share this hour grid.
    private func timeline(_ days: [Date]) -> some View {
        let columns = days.map(dayColumn)
        let compact = columns.count > 1
        let columnWidth = max(0, (gridWidth - gutter) / CGFloat(columns.count))
        return VStack(spacing: 0) {
            if compact { weekHeader(columns) }
            if days.contains(where: { !tasksOn($0).isEmpty }) {
                HStack(alignment: .top, spacing: 0) {
                    if compact { Text("Tasks").font(.caption2).foregroundStyle(.secondary).frame(width: gutter) }
                    ForEach(days, id: \.self) { day in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(tasksOn(day), id: \.calendarItemIdentifier) { task in
                                    taskRow(task, compact: compact)
                                }
                            }.padding(6)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 104)
                Divider()
            }
            if columns.contains(where: { !$0.allDay.isEmpty }) {
                if compact { weekAllDay(columns) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        CompactContactDates(events: columns[0].allDay, model: model)
                        if columns[0].allDay.contains(where: { $0.contactDateID == nil }) { Text("ALL DAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                        ForEach(columns[0].allDay.filter { $0.contactDateID == nil }, id: \.self) { eventRow($0).fixedSize(horizontal: false, vertical: true) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                }
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hourGrid(columns, columnWidth: columnWidth)
                        if compact {
                            ForEach(1..<columns.count, id: \.self) { index in
                                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 0.5, height: hourHeight * 24)
                                    .offset(x: gutter + CGFloat(index) * columnWidth)
                            }
                        }
                        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                            eventLayer(column, x: gutter + CGFloat(index) * columnWidth, width: columnWidth, compact: compact)
                        }
                        if let sweep { sweepBlock(sweep.range, day: columns[sweep.column].day, x: gutter + CGFloat(sweep.column) * columnWidth, width: columnWidth) }
                        if let today = columns.firstIndex(where: { calendar.isDateInToday($0.day) }) {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                HStack(spacing: 0) {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Rectangle().fill(.red).frame(height: 1.5)
                                }
                                .frame(width: compact ? columnWidth + 4 : nil)
                                .padding(.leading, gutter - 4 + CGFloat(today) * columnWidth)
                                .offset(y: hourOffset(context.date, dayStart: columns[today].day) - 4)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .coordinateSpace(.named("timeline"))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gridWidth = $0 }
                    .padding(.top, 8).padding(.trailing, 8)
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y / max(1, $0.contentSize.height) }) { _, fraction in
                    if zoomBase == nil { scrollFraction = fraction }
                }
                .onChange(of: zoom) { _, height in scroll.scrollTo(y: scrollFraction * (height * 24 + 8)) }
                // Pinch to fit more of the day, or to spread it out.
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        if zoomBase == nil { zoomBase = zoom }
                        zoom = min(140, max(26, (zoomBase ?? zoom) * value.magnification))
                    }
                    .onEnded { _ in zoomBase = nil })
                .onAppear {
                    let hour = columns.contains(where: { calendar.isDateInToday($0.day) }) ? calendar.component(.hour, from: .now) - 1 : 7
                    proxy.scrollTo(max(0, hour), anchor: .top)
                }
                .refreshable { await model.refresh() }
            }
        }
    }
    private func hourGrid(_ columns: [DayColumn], columnWidth: CGFloat) -> some View {
        func column(at x: CGFloat) -> Int { columnWidth > 0 ? min(columns.count - 1, max(0, Int((x - gutter) / columnWidth))) : 0 }
        return VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    hourLabels(hour)
                    VStack(spacing: 0) { Divider(); Spacer(minLength: 0) }
                }
                .frame(height: hourHeight)
                .accessibilityElement()
                .accessibilityLabel(hourLabel(hour))
                .accessibilityActions {
                    ForEach(columns, id: \.day) { column in
                        Button(columns.count > 1 ? "Add event \(column.day.formatted(.dateTime.weekday(.wide))) at \(hourLabel(hour))" : "Add event at \(hourLabel(hour))") {
                            addEvent(hour: hour, on: column.day)
                        }
                    }
                }
                .id(hour)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { payloads, location in
            let day = columns[column(at: location.x)].day
            let minutes = min(1439, max(0, Int(location.y / hourHeight * 60)))
            let target = calendar.date(bySettingHour: minutes / 60, minute: (minutes % 60 / 15) * 15, second: 0, of: day) ?? day
            return model.dropTasks(payloads, on: target, timed: true)
        }
        // Tap an empty slot to add an event at that hour.
        .onTapGesture { location in
            addEvent(hour: min(23, max(0, Int(location.y / hourHeight))), on: columns[column(at: location.x)].day)
        }
        // Touch and hold, then drag, to sweep out a new event's time.
        .gesture(HoldAndDrag { phase, start, location in
            switch phase {
            case .began, .changed:
                let index = column(at: start.x)
                let range = CalendarDates.sweep(day: columns[index].day, from: start.y, to: location.y, hourHeight: hourHeight)
                if sweep?.range != range || sweep?.column != index { sweep = (index, range) }
            case .ended:
                if let sweep { model.sheet = .newEvent(sweep.range.start, end: sweep.range.end) }
                sweep = nil
            case .cancelled:
                sweep = nil
            }
        })
        .sensoryFeedback(.selection, trigger: sweep?.range)
    }
    /// The local hour, with the second time zone's hour beside it when one is chosen.
    private func hourLabels(_ hour: Int) -> some View {
        HStack(spacing: 4) {
            if let secondZone {
                let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
                Text(time.formatted(Date.FormatStyle(timeZone: secondZone).hour().minute()))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(hourLabel(hour)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: gutter - 6, alignment: .trailing).offset(y: -7)
        .accessibilityHidden(true)
    }
    /// The new event being swept out, with its times.
    private func sweepBlock(_ range: DateInterval, day: Date, x: CGFloat, width: CGFloat) -> some View {
        let top = hourOffset(range.start, dayStart: day)
        return VStack(alignment: .leading, spacing: 1) {
            Text("New Event").font(.caption.weight(.semibold))
            Text("\(range.start.formatted(date: .omitted, time: .shortened)) – \(range.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).monospacedDigit()
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: max(0, width - 2), height: max(22, hourOffset(range.end, dayStart: day) - top - 2), alignment: .topLeading)
        .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
        .offset(x: x + 1, y: top + 1)
        .allowsHitTesting(false)
    }
    private func eventLayer(_ column: DayColumn, x: CGFloat, width: CGFloat, compact: Bool) -> some View {
        ForEach(Array(column.timed.enumerated()), id: \.offset) { index, event in
            let top = hourOffset(column.spans[index].start, dayStart: column.day)
            let height = max(22, hourOffset(column.spans[index].end, dayStart: column.day) - top - 2)
            let slot = width / CGFloat(column.layout[index].count)
            let key = dragKey(event)
            let active = drag?.key == key ? drag : nil
            let moveTarget = active.flatMap { $0.resize ? nil : $0.target }
            let newEnd = active.flatMap { $0.resize ? $0.target : nil }
            let editable = event.isWritable && !event.isAllDay
            let preparation = PlanningPreferences.bufferMinutes(event)
            if preparation > 0 {
                let begin = max(column.day, event.startDate.addingTimeInterval(-Double(preparation * 60)))
                let bufferTop = hourOffset(begin, dayStart: column.day)
                let bufferHeight = max(0, top - bufferTop)
                if bufferHeight > 0 {
                    Text("Preparation / travel").font(.caption2).lineLimit(1)
                        .foregroundStyle(event.calendarColor)
                        .padding(.horizontal, 4)
                        .frame(width: max(0, slot - 2), height: bufferHeight, alignment: .topLeading)
                        .background(event.calendarColor.opacity(0.08))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(event.calendarColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                        .clipped()
                        .offset(x: x + CGFloat(column.layout[index].column) * slot + 1, y: bufferTop)
                        .allowsHitTesting(false)
                }
            }
            eventBlock(event, compact: compact, grip: editable && height >= 30)
                .frame(width: max(0, slot - 2), height: newEnd.map { max(22, hourOffset($0, dayStart: column.day) - top - 2) } ?? height)
                .overlay(alignment: .topLeading) { if let moveTarget { dropTime(moveTarget, color: event.calendarColor).offset(y: -20) } }
                .overlay(alignment: .bottomLeading) { if let newEnd { dropTime(newEnd, color: event.calendarColor).offset(y: 20) } }
                .offset(x: x + CGFloat(column.layout[index].column) * slot + 1, y: top + 1)
                .offset(moveTarget.map { dropOffset(event, to: $0, columnWidth: width) } ?? .zero)
                .opacity(active == nil ? 1 : 0.9).zIndex(active == nil ? 0 : 1)
                .scaleEffect(moveTarget == nil ? 1 : 1.03)
                // Touch and hold, then drag to move the event; start on its bottom edge to change when it ends.
                // Times jump between quarter hours on the clock (and days, with several columns) and a tag shows
                // where it will land. The drag is measured in the timeline's space, from the hold, so it stays under the finger.
                .gesture(HoldAndDrag(enabled: editable) { phase, start, location in
                    switch phase {
                    case .began, .changed:
                        let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
                        // The bottom 18 points of a block tall enough to have its grip resize it.
                        let resize = height >= 30 && start.y > top + height - 18
                        let target = resize
                            ? CalendarDates.resizeTarget(start: event.startDate, end: event.endDate, translation: translation.height, hourHeight: hourHeight)
                            : CalendarDates.dragTarget(start: event.startDate, translation: translation, hourHeight: hourHeight, columnWidth: compact ? width : nil)
                        if drag?.target != target || drag?.resize != resize { drag = (key, target, resize) }
                    case .ended:
                        if let active = drag, active.key == key {
                            if active.resize { model.resize(event, end: active.target) } else { model.move(event, to: active.target) }
                        }
                        drag = nil
                    case .cancelled:
                        drag = nil
                    }
                })
                .sensoryFeedback(.selection, trigger: active?.target)
                .accessibilityAction(named: "Move 15 minutes later") { model.move(event, to: event.startDate.addingTimeInterval(900)) }
                .accessibilityAction(named: "Move 15 minutes earlier") { model.move(event, to: event.startDate.addingTimeInterval(-900)) }
                .accessibilityAction(named: "Make 15 minutes longer") { model.resize(event, end: event.endDate.addingTimeInterval(900)) }
                .accessibilityAction(named: "Make 15 minutes shorter") { model.resize(event, end: max(event.startDate.addingTimeInterval(900), event.endDate.addingTimeInterval(-900))) }
        }
    }
    /// How far the dragged block sits from its own spot: whole columns across and the clock difference down.
    private func dropOffset(_ event: EKEvent, to target: Date, columnWidth: CGFloat) -> CGSize {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.startDate), to: calendar.startOfDay(for: target)).day ?? 0
        let minutes = { (date: Date) in CGFloat(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)) }
        return CGSize(width: CGFloat(days) * columnWidth, height: (minutes(target) - minutes(event.startDate)) / 60 * hourHeight)
    }
    /// The time a dragged event will start (or end, when resizing), in a tag beside the block.
    private func dropTime(_ time: Date, color: Color) -> some View {
        Text(time.formatted(date: .omitted, time: .shortened))
            .font(.caption2.weight(.bold)).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
    private func weekHeader(_ columns: [DayColumn]) -> some View {
        HStack(spacing: 0) {
            // The time zones' short names sit over their columns of hours.
            Group {
                if let secondZone {
                    HStack(spacing: 4) {
                        Text(secondZone.abbreviation() ?? "").frame(maxWidth: .infinity, alignment: .trailing)
                        Text(TimeZone.current.abbreviation() ?? "")
                    }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(.trailing, 6)
                } else { Color.clear }
            }.frame(width: gutter, height: 1, alignment: .bottom).frame(maxHeight: .infinity, alignment: .bottom)
            ForEach(columns, id: \.day) { column in
                let today = calendar.isDateInToday(column.day)
                Button { date = column.day; mode = .day } label: {
                    VStack(spacing: 2) {
                        Text(column.day.formatted(.dateTime.weekday(columns.count > 3 ? .narrow : .abbreviated))).font(.caption2).foregroundStyle(.secondary)
                        Text(column.day.formatted(.dateTime.day())).font(.subheadline.weight(today ? .bold : .regular))
                            .foregroundStyle(today ? _accent.contrastingText : .primary)
                            .frame(width: 28, height: 28).background(today ? accent : .clear, in: Circle())
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(column.day.formatted(date: .complete, time: .omitted))
                .accessibilityHint("Opens this day")
            }
        }.fixedSize(horizontal: false, vertical: true).padding(.trailing, 8).padding(.vertical, 6)
    }
    private func weekAllDay(_ columns: [DayColumn]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6)
            ForEach(columns, id: \.day) { column in
                VStack(spacing: 2) {
                    ForEach(column.allDay.prefix(2), id: \.self) { event in
                        Button { model.inspect(event) } label: {
                            HStack(spacing: 3) {
                                if let symbol = event.dateSymbol { Image(systemName: symbol) }
                                Text(event.title ?? "Untitled event").lineLimit(1)
                            }.font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                                .background(event.calendarColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        }.buttonStyle(.plain)
                    }
                    if column.allDay.count > 2 {
                        Button { date = column.day; mode = .day } label: {
                            Text("+\(column.allDay.count - 2)").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(column.allDay.count - 2) more all-day events")
                        .accessibilityHint("Opens this day")
                    }
                }.frame(maxWidth: .infinity).padding(.horizontal, 1)
            }
        }.padding(.trailing, 8).padding(.vertical, 4)
    }
    private func dragKey(_ event: EKEvent) -> String { "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)" }
    private func eventBlock(_ event: EKEvent, compact: Bool = false, grip: Bool = false) -> some View {
        let color = event.calendarColor
        // A tap gesture rather than a Button: a Button claims the touch, so touch-and-hold to drag never began.
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if event.needsReply { Circle().fill(color).frame(width: 6, height: 6).accessibilityLabel("Needs reply") }
                if MeetingLink.url(for: event) != nil && !compact { Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(color) }
                Text(event.title ?? "Untitled event").font(compact ? .system(size: 11, weight: .semibold) : .caption.weight(.semibold)).lineLimit(compact ? 3 : 2)
            }
            if !compact {
                Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, compact ? 5 : 8).padding(.trailing, compact ? 2 : 4).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.2))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        // The grip marks the bottom edge, which changes when the event ends.
        .overlay(alignment: .bottom) {
            if grip { Capsule().fill(color.opacity(0.7)).frame(width: compact ? 14 : 22, height: 3).padding(.bottom, 3).accessibilityHidden(true) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.inspect(event) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.inspect(event) }
        .accessibilityLabel("\(event.title ?? "Untitled event"), \(event.startDate.formatted(date: .omitted, time: .shortened)) to \(event.endDate.formatted(date: .omitted, time: .shortened))")
    }
    private func eventRow(_ event: EKEvent, showDate: Bool = false, conflict: Bool = false) -> some View {
        let date = showDate ? event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : nil
        let place = event.location.flatMap { $0.isEmpty || MeetingLink.url(url: nil, location: $0, notes: nil) != nil ? nil : $0 }
        let preparation = PlanningPreferences.bufferMinutes(event)
        let detail = [date, place, preparation > 0 ? "\(preparation) min preparation / travel" : nil, event.hasRecurrenceRules ? "Repeats" : nil].compactMap { $0 }.joined(separator: " · ")
        return EventRow(color: event.calendarColor, title: event.title ?? "Untitled event",
                        detail: detail.isEmpty ? nil : detail,
                        time: event.isAllDay ? "All day" : "\(event.startDate.formatted(date: .omitted, time: .shortened))\n\(event.endDate.formatted(date: .omitted, time: .shortened))",
                        birthday: event.isBirthday, contactDateSymbol: event.contactDateSymbol, needsReply: event.needsReply, conflict: conflict,
                        joinURL: !event.isAllDay && event.endDate > .now ? MeetingLink.url(for: event) : nil) { model.inspect(event) }
            .contextMenu {
                if event.canDuplicate { Button("Duplicate", systemImage: "plus.square.on.square") { model.sheet = .duplicate(event) } }
                if let link = MeetingLink.url(for: event) { Link(destination: link) { Label("Join \(MeetingLink.service(link))", systemImage: "video") } }
            }
            .galleryRow()
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
    }
    private func groupTasks() -> [Date: [EKReminder]] {
        let dated = model.reminders.compactMap { reminder -> (due: Date, reminder: EKReminder)? in
            guard !reminder.isCompleted, reminder.calendar.map({ Preferences.selected($0.calendarIdentifier, reminders: true) }) == true,
                  let due = ReminderDates.due(reminder) else { return nil }
            return (due, reminder)
        }.sorted { $0.due < $1.due }
        return Dictionary(grouping: dated) { calendar.startOfDay(for: $0.due) }.mapValues { $0.map(\.reminder) }
    }
    private func tasksOn(_ day: Date) -> [EKReminder] { tasksByDay[calendar.startOfDay(for: day)] ?? [] }
    private func taskRow(_ task: EKReminder, compact: Bool = false) -> some View {
        HStack(alignment: .top, spacing: compact ? 4 : 10) {
            Button { model.toggle(task) } label: {
                Image(systemName: "circle").font(compact ? .caption : .title3)
                    .foregroundStyle(task.calendarColor).frame(minWidth: compact ? 24 : 36, minHeight: 32)
            }.buttonStyle(.plain).disabled(!task.isWritable)
                .accessibilityLabel("Complete \(task.title ?? "task")")
            Button { model.inspect(task) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title ?? "Reminder").font(compact ? .caption : .subheadline).foregroundStyle(GalleryPalette.ink)
                        .lineLimit(compact ? 2 : 3)
                    if let due = ReminderDates.due(task), task.dueDateComponents?.hour != nil {
                        Text(due.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !compact { Text(task.calendarTitle).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.buttonStyle(.plain)
        }
    }
    private func filterEvents(on day: Date) -> [EKEvent] {
        events.filter { CalendarDates.overlaps(start: $0.startDate, end: $0.endDate, day: day) }
            .sorted { if $0.isAllDay != $1.isAllDay { return $0.isAllDay }; return $0.startDate < $1.startDate }
    }
    private func eventsOn(_ day: Date) -> [EKEvent] { eventsByDay[calendar.startOfDay(for: day)] ?? filterEvents(on: day) }
    private func shift(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : mode == .year ? .year : .day
        let amount = mode == .week ? 7 : mode == .threeDay ? 3 : 1
        date = calendar.date(byAdding: component, value: direction * amount, to: date)!
    }
    private func reload() {
        model.calendarCreationDate = newEventDate
        let visible = days
        events = model.events(in: DateInterval(start: visible.first!, end: calendar.date(byAdding: .day, value: 1, to: visible.last!)!))
        tasksByDay = groupTasks()
        // The Year view only tints days, so it doesn't need each day's list.
        eventsByDay = mode == .year ? [:] : Dictionary(uniqueKeysWithValues: visible.map { (calendar.startOfDay(for: $0), filterEvents(on: $0)) })
    }
}

/// Picks a day for Day, 3 Day, and Week. Sized so a six-week month fits, and a tap on a day goes there.
struct DayPicker: View {
    @AppAccent private var accent
    @Binding var date: Date
    @State private var choice: Date
    @Environment(\.dismiss) private var dismiss
    init(date: Binding<Date>) {
        _date = date
        _choice = State(initialValue: date.wrappedValue)
    }
    var body: some View {
        NavigationStack {
            DatePicker("Go to date", selection: $choice, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(GalleryPalette.paper)
                .navigationTitle("Go to Date").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Today") { date = .now; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .tint(accent)
                // Browsing months doesn't change the selection; only tapping a day does.
                .onChange(of: choice) { _, day in
                    date = day
                    dismiss()
                }
        }
        .presentationDetents([.height(500), .large])
    }
}

/// Jumps straight to a month or a year: arrows step the year, then a tap on a month (or year) goes there.
struct MonthYearPicker: View {
    @AppAccent private var accent
    @Binding var date: Date
    /// Year view picks only a year.
    var yearsOnly = false
    @State private var year: Int
    @Environment(\.dismiss) private var dismiss
    private var calendar: Calendar { .current }

    init(date: Binding<Date>, yearsOnly: Bool = false) {
        _date = date
        self.yearsOnly = yearsOnly
        _year = State(initialValue: Calendar.current.component(.year, from: date.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    Button(yearsOnly ? "Earlier years" : "Previous year", systemImage: "chevron.left") { year -= yearsOnly ? 12 : 1 }
                    Spacer()
                    Text(yearsOnly ? "\(String(firstYear)) – \(String(firstYear + 11))" : String(year))
                        .font(.title2.bold()).monospacedDigit().contentTransition(.numericText())
                    Spacer()
                    Button(yearsOnly ? "Later years" : "Next year", systemImage: "chevron.right") { year += yearsOnly ? 12 : 1 }
                }
                .labelStyle(.iconOnly).font(.title3.weight(.semibold))
                .animation(.snappy, value: year)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    if yearsOnly {
                        ForEach(firstYear..<(firstYear + 12), id: \.self) { value in
                            cell(String(value), selected: value == calendar.component(.year, from: date),
                                 current: value == calendar.component(.year, from: .now)) { choose(year: value, month: nil) }
                        }
                    } else {
                        ForEach(1...12, id: \.self) { month in
                            cell(calendar.shortStandaloneMonthSymbols[month - 1],
                                 selected: year == calendar.component(.year, from: date) && month == calendar.component(.month, from: date),
                                 current: year == calendar.component(.year, from: .now) && month == calendar.component(.month, from: .now)) {
                                choose(year: year, month: month)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            .background(GalleryPalette.paper)
            .navigationTitle(yearsOnly ? "Go to Year" : "Go to Month").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Today") { date = .now; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(accent)
        }
        .presentationDetents([.height(yearsOnly ? 400 : 380)])
    }

    /// The twelve years shown, with the chosen year near the middle; the arrows page by twelve.
    private var firstYear: Int { year - 5 }

    private func cell(_ title: String, selected: Bool, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).monospacedDigit()
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(selected ? _accent.contrastingText : current ? accent : GalleryPalette.ink)
                .background(selected ? accent : GalleryPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(current && !selected ? accent : GalleryPalette.line, lineWidth: current && !selected ? 1.5 : 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Today when it falls in the chosen month (or year), otherwise the 1st, so the list under the month starts at the top.
    private func choose(year: Int, month: Int?) {
        let target = calendar.date(from: DateComponents(year: year, month: month ?? calendar.component(.month, from: date), day: 1)) ?? date
        date = calendar.isDate(.now, equalTo: target, toGranularity: yearsOnly ? .year : .month) ? .now : target
        dismiss()
    }
}

/// Touch and hold, then drag, on the timeline. A UIKit long press rather than a SwiftUI long press and drag:
/// SwiftUI's drag claims every touch on the timeline, so it couldn't scroll. This one lets scrolling start
/// unless the finger has held still long enough, and reports where the hold began and where the finger is now,
/// both in the timeline's coordinate space.
struct HoldAndDrag: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended, cancelled }
    var enabled = true
    let action: (Phase, _ start: CGPoint, _ location: CGPoint) -> Void
    final class Coordinator { var start = CGPoint.zero }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.3
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named("timeline"))
        switch recognizer.state {
        case .began:
            context.coordinator.start = location
            action(.began, location, location)
        case .changed: action(.changed, context.coordinator.start, location)
        case .ended: action(.ended, context.coordinator.start, location)
        default: action(.cancelled, context.coordinator.start, location)
        }
    }
}
