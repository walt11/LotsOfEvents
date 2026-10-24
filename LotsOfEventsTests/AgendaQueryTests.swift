import XCTest
@testable import LotsOfEvents

final class AgendaQueryTests: XCTestCase {
    func testWindowUsesCalendarDaysAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 15))!
        let range = AgendaQuery.window(now: now, days: 3, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: range.start), 0)
        XCTAssertEqual(calendar.component(.day, from: range.end), 10)
        XCTAssertEqual(calendar.component(.hour, from: range.end), 0)
        XCTAssertEqual(range.duration, 71 * 3600)
    }
    func testMixedAgendaIsChronological() {
        let date = Date(timeIntervalSince1970: 1000)
        let event = AgendaItem(id: "event", title: "Event", date: date.addingTimeInterval(3600), allDay: false, reminder: false, source: "", color: .blue)
        let reminder = AgendaItem(id: "reminder", title: "Reminder", date: date, allDay: true, reminder: true, source: "", color: .orange)
        XCTAssertEqual(AgendaQuery.sorted([event, reminder]).map(\.id), ["reminder", "event"])
    }
}
