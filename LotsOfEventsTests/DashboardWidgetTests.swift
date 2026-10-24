import XCTest
@testable import LotsOfEvents

final class DashboardWidgetTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.firstWeekday = 2
        return c
    }
    private func date(_ day: Int, month: Int = 10, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func testNextUpExcludesEndedAllDayAndReminders() {
        let now = date(24, hour: 12)
        func event(_ id: String, start: Int, end: Int, allDay: Bool = false, reminder: Bool = false) -> AgendaItem {
            AgendaItem(id: id, title: id, date: date(24, hour: start), allDay: allDay, reminder: reminder, source: "Test", color: .blue, endDate: date(24, hour: end))
        }
        let items = [event("ended", start: 9, end: 12), event("next", start: 14, end: 15), event("ongoing", start: 11, end: 13), event("allDay", start: 0, end: 23, allDay: true), event("task", start: 14, end: 15, reminder: true)]
        XCTAssertEqual(WidgetDashboardData.nextEvents(items, now: now).map(\.id), ["ongoing", "next"])
    }
    func testFiveDaySelectionResetsWhenSavedDateExpires() {
        let now = date(24)
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(26), now: now, month: false, calendar: calendar), date(26))
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(23), now: now, month: false, calendar: calendar), now)
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(29), now: now, month: false, calendar: calendar), now)
    }
    func testMonthSelectionCanSelectPastDayButResetsAcrossMonths() {
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(1), now: date(24), month: true, calendar: calendar), date(1))
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(30, month: 9), now: date(24), month: true, calendar: calendar), date(24))
    }
    func testMonthGridHonorsFirstWeekdayAndSixWeekMonths() {
        let grid = WidgetDashboardData.monthDays(date(15, month: 3), calendar: calendar)
        XCTAssertEqual(grid.prefix(6).compactMap { $0 }.count, 0)
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
        XCTAssertEqual((grid.count + 6) / 7, 6)
        XCTAssertEqual(grid.compactMap { $0 }.last, date(31, month: 3))
    }
    func testFocusOrdersOverdueThenScheduledThenUndatedAndPriority() {
        func task(_ id: String, due: Date?, priority: Int = 0) -> WidgetTask {
            WidgetTask(id: id, title: id, due: due, timed: false, list: "Test", color: .blue, writable: true, priority: priority)
        }
        let tasks = [task("undated", due: nil), task("later", due: date(28)), task("due", due: date(24)), task("overdue", due: date(23)), task("priority", due: date(24), priority: 1)]
        XCTAssertEqual(WidgetDashboardData.sortedTasks(tasks).map(\.id), ["overdue", "priority", "due", "later", "undated"])
    }
}
