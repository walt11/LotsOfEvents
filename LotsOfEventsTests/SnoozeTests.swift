import XCTest
import EventKit
@testable import LotsOfEvents

final class SnoozeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Chicago")!
        return value
    }
    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func testSnoozeKeepsRepeatingRuleAndMovesAbsoluteAlert() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let original = date(24, hour: 10)
        let later = date(25, hour: 10)
        reminder.dueDateComponents = ReminderDates.components(original, timed: true, calendar: calendar)
        reminder.startDateComponents = reminder.dueDateComponents
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)]
        reminder.alarms = [EKAlarm(absoluteDate: original.addingTimeInterval(-900))]
        ReminderSchedule.apply(to: reminder, due: later, timed: true, repeatRule: .keep, alert: .keep)
        XCTAssertEqual(reminder.recurrenceRules?.first?.interval, 2)
        XCTAssertEqual(reminder.recurrenceRules?.first?.frequency, .weekly)
        XCTAssertEqual(reminder.alarms?.first?.absoluteDate, later.addingTimeInterval(-900))
        XCTAssertEqual(ReminderDates.due(reminder), later)
    }
}

final class NotificationCompletionTests: XCTestCase {
    func testTravelTapCompletesOnMainThreadWhenDeliveredFromBackground() async {
        let completed = expectation(description: "Notification completed")
        completed.assertForOverFulfill = true
        await Task.detached {
            ReminderNotificationDelegate.receive(action: "com.apple.UNNotificationDefaultActionIdentifier",
                contactID: nil, timestamp: nil, reminderID: nil) {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }.value
        await fulfillment(of: [completed], timeout: 5)
    }
    func testUnknownActionStillCompletesOnMainThread() async {
        let completed = expectation(description: "Unknown action completed")
        completed.assertForOverFulfill = true
        await Task.detached {
            ReminderNotificationDelegate.receive(action: "unknown", contactID: nil, timestamp: nil, reminderID: "unused") {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }.value
        await fulfillment(of: [completed], timeout: 5)
    }
}
