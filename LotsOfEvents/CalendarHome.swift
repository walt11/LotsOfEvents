import SwiftUI
import EventKit

enum CalendarDisplay: String, CaseIterable {
    case month = "Month", week = "Week", day = "Day", agenda = "Agenda"
}

enum CalendarDates {
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
    @State private var date = Date.now
    @State private var mode = CalendarDisplay.month
    @State private var events: [EKEvent] = []
    @State private var search = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var gridWidth: CGFloat = 0
    /// `search` after a short pause, so typing doesn't refilter on every keystroke.
    @State private var query = ""
    /// Events within a year of `searchAnchor`, fetched once per search rather than per keystroke.
    @State private var searchPool: [EKEvent] = []
    @State private var searchAnchor: Date?
    @State private var datePicker = false
    private var calendar: Calendar { .current }
    private var days: [Date] {
        switch mode {
        case .month: return CalendarDates.compactMonthDays(containing: date)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .day: return [calendar.startOfDay(for: date)]
        case .agenda: return (0..<30).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: date)) }
        }
    }
    private var matchingEvents: [EKEvent] {
        guard !query.isEmpty else { return events }
        return searchPool.filter { [ $0.title, $0.location, $0.notes, $0.calendarTitle ].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showingSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search titles, places, and notes", text: $search).focused($searchFocused)
                            .submitLabel(.search).onSubmit { searchFocused = false }
                        Button("Close search", systemImage: "xmark.circle.fill") {
                            search = ""; query = ""; showingSearch = false
                        }.labelStyle(.iconOnly).foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }.padding(.leading, 12).background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal).padding(.bottom, 4)
                }
                Picker("Calendar view", selection: $mode) {
                    ForEach(CalendarDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 2)
                navigation
                if !model.calendarAccess {
                    AccessCard(title: "Your calendars, together", description: "Connect Apple Calendar to browse and manage events from your synced accounts.") { Task { await model.request(.event) } }
                } else if !query.isEmpty {
                    List {
                        Section("Search · one year before and after selected date") {
                            ForEach(matchingEvents, id: \.self) { event in eventRow(event, showDate: true) }
                            if matchingEvents.isEmpty { Text("No matching events").foregroundStyle(.secondary) }
                        }
                    }.listStyle(.insetGrouped)
                } else {
                    if mode == .month { monthGrid }
                    if mode == .day || mode == .week { timeline(mode == .week ? days : [calendar.startOfDay(for: date)]) }
                    else { agendaList }
                }
            }
            // One background for the controls and the content below them.
            .background(GalleryPalette.paper)
            .navigationTitle("Calendar")
            .galleryTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") { date = .now }
                    Button("Search calendar", systemImage: "magnifyingglass") {
                        showingSearch = true; searchFocused = true
                    }
                }
            }
            .tint(accent)
            .onAppear(perform: reload)
            .onChange(of: date) { _, _ in
                reload()
                if !query.isEmpty { loadSearchPool() }
            }
            .onChange(of: mode) { _, _ in reload() }
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !search.isEmpty && searchAnchor.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true { loadSearchPool() }
                query = search
            }
            .onChange(of: model.calendarReturnToToday) { _, _ in date = .now }
            .onChange(of: model.generation) { _, _ in
                reload()
                if query.isEmpty { searchAnchor = nil } else { loadSearchPool() }
            }
            .sheet(isPresented: $datePicker) {
                NavigationStack {
                    DatePicker("Jump to date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("Go to date").toolbar { Button("Done") { datePicker = false } }
                }.presentationDetents([.medium, .large])
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
                Text(rangeTitle).font(.system(.headline, design: .serif)).lineLimit(1).minimumScaleFactor(0.8)
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
        case .week, .agenda: return (days.first!..<days.last!).formatted(.interval.month(.abbreviated).day().year())
        }
    }
    private var monthGrid: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(spacing: 4) {
            HStack {
                ForEach(0..<7) { index in Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let selected = calendar.isDate(day, inSameDayAs: date)
                    let dayEvents = eventsOn(day)
                    Button { date = day } label: {
                        VStack(spacing: 3) {
                            Text(day.formatted(.dateTime.day())).font(.system(.subheadline, design: .rounded, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? _accent.contrastingText : calendar.isDateInToday(day) ? accent : Color.primary)
                            HStack(spacing: 2) {
                                ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                                    Capsule().fill(selected ? _accent.contrastingText : event.calendarColor).frame(width: 6, height: 3)
                                }
                                if dayEvents.count > 3 {
                                    Text("+").font(.caption2).foregroundStyle(selected ? _accent.contrastingText : .secondary)
                                }
                            }.frame(height: 8)
                        }
                        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 58 : 44)
                        .background(selected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .opacity(calendar.isDate(day, equalTo: date, toGranularity: .month) ? 1 : 0.4)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(dayEvents.count) events")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }.padding(8).gallerySurface(radius: 18).padding(.horizontal, 16).padding(.bottom, 2)
    }
    private var agendaList: some View {
        List {
            let displayedDays = mode == .month ? [calendar.startOfDay(for: date)] : days
            ForEach(displayedDays, id: \.self) { day in
                let dayEvents = eventsOn(day)
                if mode != .agenda || !dayEvents.isEmpty {
                    Section {
                        if dayEvents.isEmpty { Text("No events").foregroundStyle(.secondary).listRowBackground(GalleryPalette.card) }
                        ForEach(dayEvents, id: \.self) { event in eventRow(event) }
                    } header: { Text(day.formatted(.dateTime.weekday(.wide).month().day())).font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted) }
                }
            }
            if mode == .agenda && matchingEvents.isEmpty { ContentUnavailableView("No upcoming events", systemImage: "calendar", description: Text("Nothing scheduled in these 30 days.")) }
        }.listStyle(.insetGrouped)
            .listSectionSpacing(10)
            .contentMargins(.top, 4, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 44)
            .refreshable { await model.refresh() }
    }
    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 50
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
            if columns.contains(where: { !$0.allDay.isEmpty }) {
                if compact { weekAllDay(columns) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ALL DAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(columns[0].allDay, id: \.self) { eventRow($0).fixedSize(horizontal: false, vertical: true) }
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
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gridWidth = $0 }
                    .padding(.top, 8).padding(.trailing, 8)
                }
                .onAppear {
                    let hour = columns.contains(where: { calendar.isDateInToday($0.day) }) ? calendar.component(.hour, from: .now) - 1 : 7
                    proxy.scrollTo(max(0, hour), anchor: .top)
                }
                .refreshable { await model.refresh() }
            }
        }
    }
    private func hourGrid(_ columns: [DayColumn], columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hourLabel(hour)).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing).offset(y: -7)
                    VStack(spacing: 0) { Divider(); Spacer(minLength: 0) }
                }
                .frame(height: hourHeight)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    // Tap an empty slot to add an event at that hour on that day.
                    let index = columnWidth > 0 ? Int((location.x - gutter) / columnWidth) : 0
                    addEvent(hour: hour, on: columns[min(columns.count - 1, max(0, index))].day)
                }
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
    }
    private func eventLayer(_ column: DayColumn, x: CGFloat, width: CGFloat, compact: Bool) -> some View {
        ForEach(Array(column.timed.enumerated()), id: \.offset) { index, event in
            let top = hourOffset(column.spans[index].start, dayStart: column.day)
            let slot = width / CGFloat(column.layout[index].count)
            eventBlock(event, compact: compact)
                .frame(width: max(0, slot - 2), height: max(22, hourOffset(column.spans[index].end, dayStart: column.day) - top - 2))
                .offset(x: x + CGFloat(column.layout[index].column) * slot + 1, y: top + 1)
        }
    }
    private func weekHeader(_ columns: [DayColumn]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(columns, id: \.day) { column in
                let today = calendar.isDateInToday(column.day)
                Button { date = column.day; mode = .day } label: {
                    VStack(spacing: 2) {
                        Text(column.day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                        Text(column.day.formatted(.dateTime.day())).font(.subheadline.weight(today ? .bold : .regular))
                            .foregroundStyle(today ? _accent.contrastingText : .primary)
                            .frame(width: 28, height: 28).background(today ? accent : .clear, in: Circle())
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(column.day.formatted(date: .complete, time: .omitted))
                .accessibilityHint("Opens this day")
            }
        }.padding(.trailing, 8).padding(.vertical, 6)
    }
    private func weekAllDay(_ columns: [DayColumn]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6)
            ForEach(columns, id: \.day) { column in
                VStack(spacing: 2) {
                    ForEach(column.allDay.prefix(2), id: \.self) { event in
                        Button { model.sheet = .event(event) } label: {
                            Text(event.title ?? "Untitled event").font(.system(size: 9, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                                .background(event.calendarColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                        }.buttonStyle(.plain)
                    }
                    if column.allDay.count > 2 { Text("+\(column.allDay.count - 2)").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity).padding(.horizontal, 1)
            }
        }.padding(.trailing, 8).padding(.vertical, 4)
    }
    private func eventBlock(_ event: EKEvent, compact: Bool = false) -> some View {
        let color = event.calendarColor
        return Button { model.sheet = .event(event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled event").font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold)).lineLimit(compact ? 3 : 2)
                if !compact {
                    Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, compact ? 5 : 8).padding(.trailing, compact ? 2 : 4).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color.opacity(0.2))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title ?? "Untitled event"), \(event.startDate.formatted(date: .omitted, time: .shortened)) to \(event.endDate.formatted(date: .omitted, time: .shortened))")
    }
    private func eventRow(_ event: EKEvent, showDate: Bool = false) -> some View {
        Button { model.sheet = .event(event) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(event.calendarColor).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title ?? "Untitled event").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Text(event.isAllDay ? "All day" : "\(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))")
                        if let location = event.location, !location.isEmpty { Text("· " + location).lineLimit(1) }
                        if event.hasRecurrenceRules { Image(systemName: "repeat") }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if showDate { Text(event.startDate.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .galleryRow()
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
    }
    private func eventsOn(_ day: Date) -> [EKEvent] {
        matchingEvents.filter { CalendarDates.overlaps(start: $0.startDate, end: $0.endDate, day: day) }
            .sorted { if $0.isAllDay != $1.isAllDay { return $0.isAllDay }; return $0.startDate < $1.startDate }
    }
    private func shift(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : .day
        let amount = mode == .week ? 7 : mode == .agenda ? 30 : 1
        date = calendar.date(byAdding: component, value: direction * amount, to: date)!
    }
    private func reload() {
        model.calendarCreationDate = newEventDate
        events = model.events(in: DateInterval(start: days.first!, end: calendar.date(byAdding: .day, value: 1, to: days.last!)!))
    }
    private func loadSearchPool() {
        searchAnchor = date
        searchPool = model.events(in: DateInterval(start: calendar.date(byAdding: .year, value: -1, to: date)!, end: calendar.date(byAdding: .year, value: 1, to: date)!))
    }
}
