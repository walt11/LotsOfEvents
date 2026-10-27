import XCTest
import EventKit
@testable import LotsOfEvents

final class CalendarAndReminderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ day: Int, hour: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func testMonthGridRespectsFirstWeekdayAndIncludesWholeMonth() {
        let days = CalendarDates.monthDays(containing: date(24), calendar: calendar)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertTrue(days.contains(date(1)))
        XCTAssertTrue(days.contains(date(31)))
        XCTAssertEqual(Set(days).count, 42)
    }
    func testEventEndingAtMidnightIsNotRepeatedOnFollowingDay() {
        XCTAssertTrue(CalendarDates.overlaps(start: date(24, hour: 22), end: date(25), day: date(24), calendar: calendar))
        XCTAssertFalse(CalendarDates.overlaps(start: date(24, hour: 22), end: date(25), day: date(25), calendar: calendar))
    }
    func testMultiDayAndZeroDurationEventsRemainVisible() {
        XCTAssertTrue(CalendarDates.overlaps(start: date(23), end: date(26), day: date(24), calendar: calendar))
        XCTAssertTrue(CalendarDates.overlaps(start: date(24, hour: 9), end: date(24, hour: 9), day: date(24), calendar: calendar))
    }
    func testDayRangeUsesCalendarMathAtDSTTransition() {
        let range = CalendarDates.dayRange(date(8, month: 3), calendar: calendar)
        XCTAssertEqual(range.duration, 23 * 3600)
    }
    func testDateOnlyReminderDoesNotAcquireTimeOrTimeZone() {
        let components = ReminderDates.components(date(24, hour: 15), timed: false, calendar: calendar)
        XCTAssertEqual(components.day, 24)
        XCTAssertNil(components.hour)
        XCTAssertNil(components.minute)
        XCTAssertNil(components.timeZone)
    }
    func testTimedReminderRoundTripsDueTime() {
        let original = date(24, hour: 15)
        let components = ReminderDates.components(original, timed: true, calendar: calendar)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.timeZone, calendar.timeZone)
        XCTAssertEqual(components.calendar?.date(from: components), original)
    }
    func testExistingThemeIDsRemainAvailableAlongsideGallery() {
        XCTAssertEqual(Set(AgendaTheme.allCases.map(\.rawValue)), ["charcoal", "gallery", "graphite", "slate", "sage", "sand", "clay", "lavender", "black", "custom", "matchApp"])
    }
    func testReminderDueDateEditPreservesAlertOffset() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        let initial = date(24, hour: 15)
        reminder.dueDateComponents = ReminderDates.components(initial, timed: true, calendar: calendar)
        reminder.alarms = [EKAlarm(absoluteDate: initial.addingTimeInterval(-3600))]
        let updated = date(25, hour: 15)
        ReminderSchedule.apply(to: reminder, due: updated, timed: true, repeatRule: .keep, alert: .keep)
        XCTAssertEqual(reminder.alarms?.first?.absoluteDate, updated.addingTimeInterval(-3600))
    }
    func testRemovingDueDateClearsRecurrenceButPreservesLocationAlarm() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.dueDateComponents = ReminderDates.components(date(24), timed: false, calendar: calendar)
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Test place")
        location.proximity = .enter
        reminder.alarms = [location, EKAlarm(absoluteDate: date(24))]
        ReminderSchedule.apply(to: reminder, due: nil, timed: false, repeatRule: .keep, alert: .keep)
        XCTAssertNil(reminder.dueDateComponents)
        XCTAssertFalse(reminder.hasRecurrenceRules)
        XCTAssertEqual(reminder.alarms?.count, 1)
        XCTAssertEqual(reminder.alarms?.first?.structuredLocation?.title, "Test place")
    }
    func testKeepingComplexRecurrenceDoesNotReplaceRule() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: EKRecurrenceEnd(occurrenceCount: 8))]
        ReminderSchedule.apply(to: reminder, due: date(24), timed: false, repeatRule: .keep, alert: .keep)
        XCTAssertEqual(reminder.recurrenceRules?.first?.interval, 2)
        XCTAssertEqual(reminder.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount, 8)
    }

}

final class CompactCalendarTests: XCTestCase {
    func testCompactMonthContainsEveryDayAndOnlyNecessaryWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        for firstWeekday in [1, 2, 7] {
            calendar.firstWeekday = firstWeekday
            for month in 1...12 {
                let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 1))!
                let days = CalendarDates.compactMonthDays(containing: date, calendar: calendar)
                XCTAssertEqual(days.count % 7, 0)
                XCTAssertTrue((28...42).contains(days.count))
                XCTAssertEqual(calendar.component(.weekday, from: days[0]), firstWeekday)
                XCTAssertEqual(days.filter { calendar.isDate($0, equalTo: date, toGranularity: .month) }.count, calendar.range(of: .day, in: .month, for: date)!.count)
                XCTAssertTrue(days.suffix(7).contains { calendar.isDate($0, equalTo: date, toGranularity: .month) })
            }
        }
    }
}
