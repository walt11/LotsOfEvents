import SwiftUI
import EventKit

/// Compact Today section: the same rows as later agenda dates, with optional earlier events.
struct TodayDashboard: View {
    @ObservedObject var model: AgendaModel
    @ObservedObject private var weather = WeatherStore.shared
    let items: [AgendaItem]
    let overdue: [EKReminder]
    let undated: [EKReminder]
    @AppStorage(AppDensity.key, store: Preferences.defaults) private var densityID = AppDensity.standard.rawValue
    @AppStorage("agendaShowEarlierItems", store: Preferences.defaults) private var showEarlierItems = false
    private var conflicts: Set<String> {
        Conflicts.ids(items.filter { !$0.reminder && !$0.allDay }.map { ($0.id, $0.eventStartDate ?? $0.date, $0.endDate ?? $0.date) })
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let earlier = items.filter { !$0.reminder && !$0.allDay && ($0.endDate ?? $0.date) <= context.date }
            let upcoming = items.filter { $0.reminder || $0.allDay || ($0.endDate ?? $0.date) > context.date }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionHeader(title: "Today · \(context.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))")
                    Spacer(minLength: 0)
                    if let forecast = weather.forecast(for: context.date) { WeatherBadge(forecast: forecast) }
                }
                if showEarlierItems && !earlier.isEmpty {
                    SectionHeader(title: "Earlier today")
                    ForEach(earlier) { row($0, dimmed: true) }
                }
                CompactContactDates(items: upcoming, model: model)
                ForEach(upcoming.filter { $0.contactDateID == nil }) { row($0) }
                if upcoming.isEmpty && overdue.isEmpty && undated.isEmpty {
                    Text("Nothing else scheduled today").font(.caption).foregroundStyle(GalleryPalette.muted).padding(.vertical, 4)
                }
                if !overdue.isEmpty {
                    SectionHeader(title: "Overdue", tint: GalleryPalette.alert).padding(.top, 4)
                    ForEach(overdue.map(Self.item)) { row($0) }
                }
                if !undated.isEmpty {
                    SectionHeader(title: "Anytime").padding(.top, 4)
                    ForEach(undated.map(Self.item)) { row($0) }
                }
                if showEarlierItems {
                    let completed = model.completedToday.filter { reminder in
                        guard let list = reminder.calendar else { return false }
                        return Preferences.selected(list.calendarIdentifier, reminders: true)
                    }.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                    if !completed.isEmpty {
                        SectionHeader(title: "Completed today").padding(.top, 4)
                        ForEach(completed.map(Self.item)) { row($0, dimmed: true, completed: true) }
                    }
                }
            }
        }
    }

    private func row(_ item: AgendaItem, dimmed: Bool = false, completed: Bool = false) -> some View {
        EventRow(color: item.color, title: item.title, detail: item.agendaDetail, time: completed ? "Done" : item.timeLabel,
                 birthday: item.birthday, contactDateSymbol: item.contactDateSymbol, needsReply: item.needsReply, conflict: !dimmed && conflicts.contains(item.id),
                 joinURL: (item.endDate ?? item.date) > .now ? item.joinURL : nil, dimmed: dimmed) { model.open(item) } leading: {
            if item.reminder {
                Button { if let reminder = model.reminder(withID: item.id) { model.toggle(reminder) } } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(item.color).frame(width: 28, height: 36)
                }.buttonStyle(.borderless).accessibilityLabel(completed ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
            }
        }
        .padding(.vertical, (AppDensity(rawValue: densityID) ?? .standard).rowPadding)
        .deletableAgendaItem(model: model, item: item) {
            if let reminder = model.reminder(withID: item.id), item.reminder && !completed { SnoozeButtons(model: model, reminder: reminder) }
        }
    }
    static func item(_ reminder: EKReminder) -> AgendaItem {
        let due = ReminderDates.due(reminder)
        return AgendaItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", date: due ?? .now,
                   allDay: reminder.dueDateComponents?.hour == nil, reminder: true, source: reminder.calendarTitle,
                   color: reminder.calendarColor, notes: reminder.notes)
    }
}
