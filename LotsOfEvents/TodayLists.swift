import SwiftUI
import EventKit

extension AgendaModel {
    /// Reminders the Agenda's Today section adds to its own items: overdue ones from the shown lists, and undated ones
    /// from the lists chosen for Today. Reminders due today are already among the day's items.
    func todayExtras(now: Date = .now) -> (overdue: [EKReminder], undated: [EKReminder]) {
        let undatedLists = TodayTasks.undatedLists
        let today = Calendar.current.startOfDay(for: now)
        var overdue: [EKReminder] = [], undated: [EKReminder] = []
        for reminder in reminders where !reminder.isCompleted {
            guard let id = reminder.calendar?.calendarIdentifier else { continue }
            let due = ReminderDates.due(reminder)
            guard TodayTasks.includes(due: due, listID: id, shown: Preferences.selected(id, reminders: true), now: now, undatedLists: undatedLists) else { continue }
            if let due { if due < today { overdue.append(reminder) } } else { undated.append(reminder) }
        }
        let order = { (a: EKReminder, b: EKReminder) in ReminderOrder.precedes(a, b, byPriority: false) }
        return (overdue.sorted(by: order), undated.sorted(by: order))
    }
}

/// Chooses the lists whose undated reminders appear in Today, in the Agenda and the Events + Tasks widget.
struct TodayListsView: View {
    @ObservedObject var model: AgendaModel
    @State private var chosen = TodayTasks.undatedLists
    var body: some View {
        let accounts = Dictionary(grouping: model.lists, by: { $0.source.title }).sorted { $0.key < $1.key }
        List {
            if !model.reminderAccess {
                Section { Button("Connect Apple Reminders") { Task { await model.request(.reminder) } } }
            } else if model.lists.isEmpty { ContentUnavailableView("No lists yet", systemImage: "checklist") }
            ForEach(accounts, id: \.key) { account, lists in
                Section(account) {
                    ForEach(lists, id: \.calendarIdentifier) { list in
                        Toggle(isOn: Binding(get: { chosen.contains(list.calendarIdentifier) }, set: { on in
                            if on { chosen.insert(list.calendarIdentifier) } else { chosen.remove(list.calendarIdentifier) }
                            TodayTasks.undatedLists = chosen
                            model.objectWillChange.send()
                            WidgetReloader.schedule()
                        })) {
                            HStack(spacing: 12) {
                                Circle().fill(Color(cgColor: list.cgColor)).frame(width: 10, height: 10)
                                Text(list.title)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Reminders without a due date from these lists appear in Today in the Agenda and in the Events + Tasks widget, alongside today's events and reminders that are due or overdue.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .navigationTitle("Undated in Today").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
    /// "None", one list's name, or a count.
    static func summary(_ model: AgendaModel) -> String {
        let chosen = model.lists.filter { TodayTasks.undatedLists.contains($0.calendarIdentifier) }
        if chosen.isEmpty { return "None chosen" }
        return chosen.count == 1 ? chosen[0].title : "\(chosen.count) lists"
    }
}
