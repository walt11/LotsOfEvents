import SwiftUI
import EventKit

extension AgendaModel {
    func reminder(withID id: String) -> EKReminder? { store.calendarItem(withIdentifier: id) as? EKReminder }
    /// Moves a reminder to an hour from now, or to the same time tomorrow (9 AM for reminders without a time).
    func snooze(_ reminder: EKReminder, tomorrow: Bool) {
        guard tomorrow else { snooze(reminder, until: Date.now.addingTimeInterval(3600), timed: true); return }
        let calendar = Calendar.current
        let parts = reminder.dueDateComponents
        let day = calendar.date(byAdding: .day, value: 1, to: .now)!
        let due = calendar.date(bySettingHour: parts?.hour ?? 9, minute: parts?.minute ?? 0, second: 0, of: day)!
        snooze(reminder, until: due, timed: parts?.hour != nil)
    }
    func snooze(_ reminder: EKReminder, until date: Date, timed: Bool) {
        guard let current = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
              current.isWritable, !current.isCompleted else { error = "This reminder is no longer available to snooze."; return }
        let previous = ReminderSnapshot(current)
        ReminderSchedule.apply(to: current, due: date, timed: timed, repeatRule: .keep, alert: .keep)
        do {
            try store.save(current, commit: true)
            undo = UndoAction(message: "Rescheduled “\(current.title ?? "Reminder")”") { [weak self] in
                guard let self, let item = self.store.calendarItem(withIdentifier: current.calendarItemIdentifier) as? EKReminder else { return }
                item.dueDateComponents = previous.due
                item.startDateComponents = previous.start
                item.recurrenceRules = previous.rules
                item.alarms = previous.alarms
                do { try self.store.save(item, commit: true); self.scheduleRefresh() }
                catch { _ = item.refresh(); self.error = error.localizedDescription }
            }
            scheduleRefresh()
        } catch { _ = current.refresh(); self.error = error.localizedDescription }
    }
}

/// Swipe actions for postponing a reminder.
struct SnoozeButtons: View {
    @ObservedObject var model: AgendaModel
    let reminder: EKReminder
    var body: some View {
        if reminder.isWritable && !reminder.isCompleted {
            Button("Tomorrow", systemImage: "sunrise") { model.snooze(reminder, tomorrow: true) }.tint(.indigo)
            Button("1 Hour", systemImage: "clock.arrow.circlepath") { model.snooze(reminder, tomorrow: false) }.tint(.orange)
        }
    }
}
