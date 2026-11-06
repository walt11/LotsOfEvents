import XCTest
import EventKit
@testable import LotsOfEvents

final class PlanningFeatureTests: XCTestCase {
    func testMonthlyQuickAddKeepsTitleAndSpecificRecurrenceDay() {
        let parsed = QuickAddParser.parse("Pay rent every month on the first")
        XCTAssertEqual(parsed.title, "Pay rent")
        XCTAssertEqual(parsed.repeats?.monthDay, 1)
        XCTAssertEqual(parsed.repeats?.rule.daysOfTheMonth, [1])
        XCTAssertEqual(Calendar.current.component(.day, from: parsed.date!), 1)
        XCTAssertTrue(parsed.allDay)
        let other = QuickAddParser.parse("Pay bill monthly on the 15th at 10am")
        XCTAssertEqual(other.title, "Pay bill")
        XCTAssertEqual(other.repeats?.monthDay, 15)
        XCTAssertEqual(Calendar.current.component(.day, from: other.date!), 15)
        XCTAssertEqual(Calendar.current.component(.hour, from: other.date!), 10)
        XCTAssertFalse(other.allDay)
    }
    func testWidgetResetOffAndLongerTimeout() {
        let name = "PlanningTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 10000)
        defaults.set(now.timeIntervalSince1970, forKey: "test")
        defaults.set(0.0, forKey: "widgetReset.test")
        XCTAssertNil(WidgetDayNavigation.resetDate(key: "test", in: defaults))
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(1000), key: "test", in: defaults))
        defaults.set(300.0, forKey: "widgetReset.test")
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(299), key: "test", in: defaults))
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now.addingTimeInterval(300), key: "test", in: defaults))
    }
    func testUnrelatedDragCannotScheduleTask() {
        XCTAssertNil(ReminderDrag.identifier("https://example.com"))
        XCTAssertNil(ReminderDrag.identifier(ReminderDrag.prefix))
        XCTAssertEqual(ReminderDrag.identifier(ReminderDrag.payload("task-123")), "task-123")
    }
    func testPreparationDetectsTightGaps() {
        let end = Date(timeIntervalSince1970: 10000)
        XCTAssertTrue(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(600), minutes: 15))
        XCTAssertFalse(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(900), minutes: 15))
        XCTAssertTrue(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(-60), minutes: 0))
    }
    @MainActor func testWidgetCompletionCanBeUndone() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw XCTSkip("Reminder permission required") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.title = "LotsOfEvents test undo \(UUID())"
        let previous = Preferences.defaults.data(forKey: WidgetUndoRecord.key)
        defer {
            try? store.remove(reminder, commit: true)
            if let previous { Preferences.defaults.set(previous, forKey: WidgetUndoRecord.key) }
            else { Preferences.defaults.removeObject(forKey: WidgetUndoRecord.key) }
        }
        try store.save(reminder, commit: true)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        let record = WidgetUndoRecord(token: UUID().uuidString, identifier: reminder.calendarItemIdentifier, title: reminder.title!, completedAt: reminder.completionDate!)
        record.save()
        try WidgetUndoRecord.undo(token: "stale-token")
        _ = reminder.refresh()
        XCTAssertTrue(reminder.isCompleted)
        try WidgetUndoRecord.undo(token: record.token)
        _ = reminder.refresh()
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertNil(WidgetUndoRecord.current)
    }
    @MainActor func testTaskDropSetsDueDateAndSupportsUndo() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw XCTSkip("Reminder permission required") }
        let model = AgendaModel()
        let reminder = EKReminder(eventStore: model.store)
        reminder.calendar = model.store.defaultCalendarForNewReminders()
        reminder.title = "LotsOfEvents test drag \(UUID())"
        try model.store.save(reminder, commit: true)
        defer { try? model.store.remove(reminder, commit: true) }
        let target = Calendar.current.date(bySettingHour: 14, minute: 15, second: 0, of: .now)!
        XCTAssertTrue(model.dropTasks([ReminderDrag.payload(reminder.calendarItemIdentifier)], on: target, timed: true))
        _ = reminder.refresh()
        XCTAssertEqual(ReminderDates.due(reminder), target)
        model.undo?.perform()
        _ = reminder.refresh()
        XCTAssertNil(reminder.dueDateComponents)
    }

}
