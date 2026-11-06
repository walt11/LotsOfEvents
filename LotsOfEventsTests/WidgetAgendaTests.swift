import XCTest
@testable import LotsOfEvents

final class WidgetAgendaTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var day: Date { Date(timeIntervalSince1970: 1_792_800_000) }
    private func item(_ id: String, date: Date? = nil, allDay: Bool = true) -> AgendaItem {
        AgendaItem(id: id, title: id, date: date ?? day, allDay: allDay, reminder: false, source: "Test", color: .blue)
    }
    func testTimedSubtitlesConsumeSpaceInPagination() {
        let rows = [item("a"), item("b", allDay: false), item("c", allDay: false)]
        let pages = WidgetAgendaLayout.pages(items: rows, height: 42, headings: false, calendar: calendar)
        XCTAssertEqual(pages.map { $0.map(\.id) }, [["a", "b"], ["c"]])
    }
    func testNewPageIncludesItsDateHeadingBudget() {
        let rows = [item("a"), item("b"), item("c")]
        let pages = WidgetAgendaLayout.pages(items: rows, height: 30, headings: true, calendar: calendar)
        XCTAssertEqual(pages.map(\.count), [1, 1, 1])
        XCTAssertEqual(pages.flatMap { $0 }.map(\.id), rows.map(\.id))
    }
    func testThreeDaySelectionIncludesOverlappingEventsWithoutMidnightDuplicates() {
        let start = calendar.startOfDay(for: day)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let next = calendar.date(byAdding: .day, value: 2, to: start)!
        var multi = item("multi", date: start)
        multi.eventStartDate = start
        multi.endDate = next
        var ending = item("ends", date: start)
        ending.eventStartDate = start
        ending.endDate = tomorrow
        var reminder = item("reminder", date: tomorrow)
        reminder = AgendaItem(id: reminder.id, title: reminder.title, date: tomorrow, allDay: true, reminder: true, source: "Test", color: .blue)
        let result = WidgetAgendaLayout.items(on: tomorrow, from: [ending, multi, reminder], calendar: calendar)
        XCTAssertEqual(Set(result.map(\.id)), ["multi", "reminder"])
    }
    func testThreeDayTodayKeepsFinishedMorningEventsInTheAfternoon() {
        let start = calendar.startOfDay(for: day)
        let afternoon = start.addingTimeInterval(15 * 3600)
        var morning = item("morning", date: start.addingTimeInterval(9 * 3600), allDay: false)
        morning.endDate = start.addingTimeInterval(10 * 3600)
        var evening = item("evening", date: start.addingTimeInterval(18 * 3600), allDay: false)
        evening.endDate = start.addingTimeInterval(19 * 3600)
        let range = AgendaQuery.window(now: afternoon, days: 3, calendar: calendar)
        XCTAssertEqual(range.start, start)
        XCTAssertTrue(range.contains(morning.date))
        let rows = WidgetAgendaLayout.items(on: afternoon, from: [evening, morning], calendar: calendar)
        XCTAssertEqual(rows.map(\.id), ["morning", "evening"])
        XCTAssertEqual(WidgetScroll.visible([29, 29], from: 0, in: 100), 2)
    }
    func testTimeRangeAndReminderTimeUseDifferentFormats() {
        var event = item("event", allDay: false)
        event.endDate = day.addingTimeInterval(3600)
        XCTAssertTrue(event.widgetTimeLabel.contains("–"))
        let reminder = AgendaItem(id: "reminder", title: "Reminder", date: day, allDay: false, reminder: true, source: "Test", color: .blue)
        XCTAssertEqual(reminder.widgetTimeLabel, day.formatted(date: .omitted, time: .shortened))
    }
}
