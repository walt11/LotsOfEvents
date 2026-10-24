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
}

struct CalendarHome: View {
    @ObservedObject var model: AgendaModel
    @State private var date = Date.now
    @State private var mode = CalendarDisplay.month
    @State private var events: [EKEvent] = []
    @State private var search = ""
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
        guard !search.isEmpty else { return events }
        return events.filter { [ $0.title, $0.location, $0.notes, $0.calendar.title ].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search) }
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
                } else if !search.isEmpty {
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
            .onChange(of: date) { _, _ in reload() }
            .onChange(of: mode) { _, _ in reload() }
            .onChange(of: search) { _, _ in reload() }
            .onChange(of: model.generation) { _, _ in reload() }
            .sheet(isPresented: $datePicker) {
                NavigationStack {
                    DatePicker("Jump to date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("Go to date").toolbar { Button("Done") { datePicker = false } }
                }.presentationDetents([.medium, .large])
            }
        }
    }
    private var newEventDate: Date {
        calendar.isDateInToday(date) ? .now : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
    }
    private var navigation: some View {
        HStack {
            Button("Previous \(mode.rawValue.lowercased())", systemImage: "chevron.left") { shift(-1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
            Spacer()
            Button { datePicker = true } label: {
                Text(date.formatted(mode == .day ? .dateTime.month().day().year() : .dateTime.month(.wide).year())).font(.headline)
                Image(systemName: "chevron.down").font(.caption)
            }.foregroundStyle(.primary)
            Spacer()
            Button("Next \(mode.rawValue.lowercased())", systemImage: "chevron.right") { shift(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.padding(.horizontal, 8)
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
    private var daySchedule: some View {
        List {
            let dayEvents = eventsOn(date)
            let allDay = dayEvents.filter(\.isAllDay)
            if !allDay.isEmpty {
                Section("All day") { ForEach(allDay, id: \.self) { eventRow($0) } }
            }
            Section(date.formatted(.dateTime.weekday(.wide).month().day())) {
                ForEach(0..<24) { hour in
                    let hourDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
                    let hourEvents = dayEvents.filter { !$0.isAllDay && calendar.component(.hour, from: max($0.startDate, calendar.startOfDay(for: date))) == hour }
                    HStack(alignment: .top, spacing: 10) {
                        Text(hourDate.formatted(.dateTime.hour())).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            if hourEvents.isEmpty {
                                Button { model.sheet = .newEvent(hourDate) } label: { Color.clear.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Add event at \(hourDate.formatted(date: .omitted, time: .shortened))")
                            }
                            ForEach(hourEvents, id: \.self) { eventRow($0) }
                        }
                    }.padding(.vertical, 3)
                }
            }
        }.listStyle(.plain).refreshable { await model.refresh() }
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
        let start: Date
        let end: Date
        if !search.isEmpty {
            start = calendar.date(byAdding: .year, value: -1, to: date)!
            end = calendar.date(byAdding: .year, value: 1, to: date)!
        } else {
            start = days.first!
            end = calendar.date(byAdding: .day, value: 1, to: days.last!)!
        }
        events = model.events(in: DateInterval(start: start, end: end))
    }
}
