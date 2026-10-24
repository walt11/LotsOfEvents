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
    @ObservedObject var model: AgendaModel
    @State private var date = Date.now
    @State private var mode = CalendarDisplay.month
    @State private var events: [EKEvent] = []
    @State private var search = ""
    /// `search` after a short pause, so typing doesn't refilter on every keystroke.
    @State private var query = ""
    /// Events within a year of `searchAnchor`, fetched once per search rather than per keystroke.
    @State private var searchPool: [EKEvent] = []
    @State private var searchAnchor: Date?
    @State private var datePicker = false
    private var calendar: Calendar { .current }
    private var days: [Date] {
        switch mode {
        case .month: return CalendarDates.monthDays(containing: date)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .day: return [calendar.startOfDay(for: date)]
        case .agenda: return (0..<30).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: date)) }
        }
    }
    private var matchingEvents: [EKEvent] {
        guard !query.isEmpty else { return events }
        return searchPool.filter { [ $0.title, $0.location, $0.notes, $0.calendar.title ].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Calendar view", selection: $mode) {
                    ForEach(CalendarDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
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
                    if mode == .day { daySchedule }
                    else { agendaList }
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search titles, places, and notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Sources", systemImage: "slider.horizontal.3") { model.sheet = .sources } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") { date = .now }
                    Button("New event", systemImage: "plus") { model.sheet = .newEvent(newEventDate) }
                }
            }
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
                Text(rangeTitle).font(.headline)
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
                            Text(day.formatted(.dateTime.day())).font(.system(.body, design: .rounded, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? Color.white : calendar.isDateInToday(day) ? Color.teal : Color.primary)
                            HStack(spacing: 2) {
                                ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                                    Circle().fill(selected ? .white : Color(cgColor: event.calendar.cgColor)).frame(width: 4, height: 4)
                                }
                            }.frame(height: 4)
                        }
                        .frame(maxWidth: .infinity, minHeight: 35)
                        .background(selected ? Color.teal : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .opacity(calendar.isDate(day, equalTo: date, toGranularity: .month) ? 1 : 0.4)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(dayEvents.count) events")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }.padding(.horizontal).padding(.bottom, 8)
    }
    private var agendaList: some View {
        List {
            let displayedDays = mode == .month ? [calendar.startOfDay(for: date)] : days
            ForEach(displayedDays, id: \.self) { day in
                let dayEvents = eventsOn(day)
                if mode != .agenda || !dayEvents.isEmpty {
                    Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                        if dayEvents.isEmpty { Text("No events").foregroundStyle(.secondary) }
                        ForEach(dayEvents, id: \.self) { event in eventRow(event) }
                    }
                }
            }
            if mode == .agenda && matchingEvents.isEmpty { ContentUnavailableView("No upcoming events", systemImage: "calendar", description: Text("Nothing scheduled in these 30 days.")) }
        }.listStyle(.insetGrouped).refreshable { await model.refresh() }
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
    private var daySchedule: some View {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let dayEvents = eventsOn(date)
        let allDay = dayEvents.filter(\.isAllDay)
        let timed = dayEvents.filter { !$0.isAllDay }
        // Short and zero-length events still take 15 minutes, so they stay readable and tappable.
        let spans = timed.map { event -> DateInterval in
            let start = max(event.startDate, dayStart)
            return DateInterval(start: start, end: max(start, min(max(event.endDate, start.addingTimeInterval(900)), dayEnd)))
        }
        let layout = CalendarDates.columns(spans)
        return VStack(spacing: 0) {
            if !allDay.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ALL DAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(allDay, id: \.self) { eventRow($0).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                let hourDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
                                HStack(alignment: .top, spacing: 6) {
                                    Text(hourDate.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.secondary)
                                        .frame(width: gutter - 6, alignment: .trailing).offset(y: -7)
                                    VStack(spacing: 0) { Divider(); Spacer(minLength: 0) }
                                }
                                .frame(height: hourHeight)
                                .contentShape(Rectangle())
                                .onTapGesture { model.sheet = .newEvent(hourDate) }
                                .accessibilityElement()
                                .accessibilityLabel("Add event at \(hourDate.formatted(date: .omitted, time: .shortened))")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { model.sheet = .newEvent(hourDate) }
                                .id(hour)
                            }
                        }
                        GeometryReader { geometry in
                            let width = geometry.size.width - gutter - 4
                            ForEach(Array(timed.enumerated()), id: \.offset) { index, event in
                                let top = hourOffset(spans[index].start, dayStart: dayStart)
                                let columnWidth = width / CGFloat(layout[index].count)
                                eventBlock(event)
                                    .frame(width: max(0, columnWidth - 2), height: max(22, hourOffset(spans[index].end, dayStart: dayStart) - top - 2))
                                    .offset(x: gutter + CGFloat(layout[index].column) * columnWidth, y: top + 1)
                            }
                        }
                        if calendar.isDateInToday(date) {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                HStack(spacing: 0) {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Rectangle().fill(.red).frame(height: 1.5)
                                }
                                .padding(.leading, gutter - 4)
                                .offset(y: hourOffset(context.date, dayStart: dayStart) - 4)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .padding(.top, 8).padding(.trailing, 8)
                }
                .onAppear {
                    let hour = calendar.isDateInToday(date) ? calendar.component(.hour, from: .now) - 1 : 7
                    proxy.scrollTo(max(0, hour), anchor: .top)
                }
                .refreshable { await model.refresh() }
            }
        }
    }
    private func eventBlock(_ event: EKEvent) -> some View {
        let color = Color(cgColor: event.calendar.cgColor)
        return Button { model.sheet = .event(event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled event").font(.caption.weight(.semibold)).lineLimit(2)
                Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
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
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title ?? "Untitled event").font(.body.weight(.medium)).foregroundStyle(.primary)
                    if showDate { Text(event.startDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    Text(event.isAllDay ? "All day" : "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if let location = event.location, !location.isEmpty { Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if event.hasRecurrenceRules { Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 3)
        }.buttonStyle(.plain)
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
        events = model.events(in: DateInterval(start: days.first!, end: calendar.date(byAdding: .day, value: 1, to: days.last!)!))
    }
    private func loadSearchPool() {
        searchAnchor = date
        searchPool = model.events(in: DateInterval(start: calendar.date(byAdding: .year, value: -1, to: date)!, end: calendar.date(byAdding: .year, value: 1, to: date)!))
    }
}
