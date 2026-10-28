import SwiftUI
import EventKit

@main
struct LotsOfEventsWatchApp: App {
    var body: some Scene { WindowGroup { WatchAgendaView() } }
}

/// Today and the next two days of events, plus reminders that are overdue or due today (read only), from the watch's own
/// copy of Calendar and Reminders.
@MainActor final class WatchAgenda: ObservableObject {
    let store = EKEventStore()
    @Published var days: [(date: Date, events: [EKEvent])] = []
    @Published var reminders: [EKReminder] = []
    @Published var calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    func requestAccess() async {
        calendarAccess = (try? await store.requestFullAccessToEvents()) ?? false
        reminderAccess = (try? await store.requestFullAccessToReminders()) ?? false
        await load()
    }
    func load() async {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        if calendarAccess {
            let end = calendar.date(byAdding: .day, value: 3, to: start)!
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { $0.isAllDay || $0.endDate > .now }
                .sorted { $0.startDate < $1.startDate }
            days = (0..<3).map { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start)!
                return (day, events.filter { calendar.isDate(max($0.startDate, start), inSameDayAs: day) })
            }
        }
        if reminderAccess {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: tomorrow, calendars: nil)
            let found: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: WatchReminders(value: $0 ?? []).value) }
            }
            reminders = found.sorted { ($0.dueDateComponents?.date ?? .distantPast) < ($1.dueDateComponents?.date ?? .distantPast) }
        }
    }
}

/// Carries reminders out of EventKit's callback.
struct WatchReminders: @unchecked Sendable { let value: [EKReminder] }

struct WatchAgendaView: View {
    @StateObject private var agenda = WatchAgenda()
    var body: some View {
        NavigationStack {
            List {
                if !agenda.calendarAccess && !agenda.reminderAccess {
                    Button("Connect Calendar & Reminders") { Task { await agenda.requestAccess() } }
                }
                ForEach(agenda.days, id: \.date) { day in
                    Section(title(day.date)) {
                        if day.events.isEmpty { Text("No events").foregroundStyle(.secondary) }
                        ForEach(day.events, id: \.eventIdentifier) { event in row(event) }
                    }
                }
                if agenda.reminderAccess {
                    Section("Reminders") {
                        if agenda.reminders.isEmpty { Text("All caught up").foregroundStyle(.secondary) }
                        // watchOS can read reminders but not change them, so they're completed on iPhone.
                        ForEach(agenda.reminders, id: \.calendarItemIdentifier) { reminder in
                            HStack {
                                Image(systemName: "circle").foregroundStyle(Color(cgColor: reminder.calendar.cgColor))
                                Text(reminder.title ?? "Reminder").lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("LotsOfEvents")
        }
        .task { await agenda.load() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await agenda.load() } }
    }
    private func title(_ day: Date) -> String {
        Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide))
    }
    private func row(_ event: EKEvent) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Event").font(.headline).lineLimit(2)
                Text(event.isAllDay ? "All day" : "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty { Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}
