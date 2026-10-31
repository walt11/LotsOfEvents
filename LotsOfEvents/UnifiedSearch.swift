import SwiftUI
import EventKit

/// Search results across events (a year either side of today) and open reminders, shown in the search sheet.
struct UnifiedSearchResults: View {
    @ObservedObject var model: AgendaModel
    let query: String
    @State private var pool: [EKEvent] = []
    private var events: [EKEvent] { pool.filter { UnifiedSearch.matches([$0.title, $0.location, $0.notes, $0.calendarTitle], query) } }
    private var reminders: [EKReminder] {
        model.reminders.filter { !$0.isCompleted && UnifiedSearch.matches([$0.title, $0.notes, $0.calendarTitle], query) }
            .sorted { ReminderOrder.precedes($0, $1, byPriority: false) }
    }
    var body: some View {
        let events = events, reminders = reminders
        List {
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
                                 birthday: event.isBirthday) { model.inspect(event) }
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
            pool = model.events(in: DateInterval(start: calendar.date(byAdding: .year, value: -1, to: .now)!, end: calendar.date(byAdding: .year, value: 1, to: .now)!))
        }
    }
}

enum UnifiedSearch {
    static func matches(_ fields: [String?], _ query: String) -> Bool {
        fields.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}
