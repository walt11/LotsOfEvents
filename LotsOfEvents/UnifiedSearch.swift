import SwiftUI
import EventKit

/// Search results across events (a year either side of today) and open reminders, shown in the search sheet.
struct UnifiedSearchResults: View {
    @ObservedObject var model: AgendaModel
    let query: String
    enum Filter: String, CaseIterable { case all = "All", upcoming = "Upcoming", past = "Past", completed = "Completed", contacts = "Contact Dates" }
    @State private var filter = Filter.all
    @State private var completed: [EKReminder] = []
    @State private var pool: [EKEvent] = []
    private var events: [EKEvent] { pool.filter {
        UnifiedSearch.matches([$0.title, $0.location, $0.notes, $0.calendarTitle], query) &&
        (filter == .all || (filter == .contacts && $0.contactDateID != nil) || (filter == .upcoming && $0.endDate > .now) || (filter == .past && $0.endDate <= .now))
    } }
    private var reminders: [EKReminder] {
        (filter == .completed ? completed : model.reminders).filter {
            filter != .contacts && (filter == .completed ? $0.isCompleted : !$0.isCompleted) &&
            $0.calendar.map { Preferences.selected($0.calendarIdentifier, reminders: true) } == true &&
            UnifiedSearch.matches([$0.title, $0.notes, $0.calendarTitle], query) &&
            (filter != .upcoming || (ReminderDates.due($0).map { $0 >= .now } ?? false)) &&
            (filter != .past || ReminderDates.isOverdue($0))
        }
            .sorted { ReminderOrder.precedes($0, $1, byPriority: false) }
    }
    var body: some View {
        let events = events, reminders = reminders
        List {
            Section {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text("Events and contact dates: one year before and after today. Completed tasks: past year.").font(.caption).foregroundStyle(.secondary)
            }
            if events.isEmpty && reminders.isEmpty {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
            if !reminders.isEmpty {
                Section {
                    ForEach(reminders, id: \.calendarItemIdentifier) { reminder in
                        ReminderLine(model: model, reminder: reminder).listRowBackground(GalleryPalette.card)
                    }
                } header: { SectionHeader(title: "Reminders", trailing: "\(reminders.count)") }
            }
            if !events.isEmpty {
                Section {
                    ForEach(events, id: \.self) { event in
                        EventRow(color: event.calendarColor, title: event.title ?? "Untitled event",
                                 detail: [event.startDate.formatted(date: .abbreviated, time: .omitted), event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                 time: event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened),
                                 birthday: event.isBirthday, contactDateSymbol: event.contactDateSymbol) { model.inspect(event) }
                            .listRowBackground(GalleryPalette.card)
                    }
                } header: { SectionHeader(title: "Events", trailing: "\(events.count)") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .scrollDismissesKeyboard(.immediately)
        // Fetch the year either side once, then filter as the text changes.
        .task(id: model.generation) {
            let calendar = Calendar.current
            if model.reminderAccess {
                completed = await model.store.reminders(matching: model.store.predicateForCompletedReminders(withCompletionDateStarting: calendar.date(byAdding: .year, value: -1, to: .now), ending: nil, calendars: nil))
            }
            pool = model.events(in: DateInterval(start: calendar.date(byAdding: .year, value: -1, to: .now)!, end: calendar.date(byAdding: .year, value: 1, to: .now)!))
        }
    }
}

enum UnifiedSearch {
    static func matches(_ fields: [String?], _ query: String) -> Bool {
        fields.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}
