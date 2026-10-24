import XCTest
@testable import LotsOfEvents

final class ContinuousAgendaTests: XCTestCase {
    @MainActor
    func testPagesAreContiguousAndIncludeEmptyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let first = ContinuousAgenda.page(items: [], start: start, calendar: calendar)
        let next = calendar.date(byAdding: .day, value: 30, to: start)!
        let second = ContinuousAgenda.page(items: [], start: next, calendar: calendar)
        XCTAssertEqual(first.count, 30)
        XCTAssertEqual(second.count, 30)
        XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: first.last!.date), second.first!.date)
        XCTAssertEqual(Set((first + second).map(\.id)).count, 60)
        XCTAssertTrue(first.allSatisfy { $0.items.isEmpty })
    }
}

final class AgendaSectionTests: XCTestCase {
    @MainActor
    func testEmptyRunsCollapseButTodayStays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        func day(_ offset: Int, busy: Bool = false) -> AgendaDay {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            return AgendaDay(date: date, items: busy ? [AgendaItem(id: "\(offset)", title: "x", date: date, allDay: true, reminder: false, source: "", color: .blue)] : [])
        }
        let sections = ContinuousAgenda.sections([day(0), day(1), day(2), day(3, busy: true), day(4)], today: today, calendar: calendar)
        guard sections.count == 4 else { return XCTFail("Expected 4 sections, got \(sections.count)") }
        if case .day(let first) = sections[0] { XCTAssertEqual(first.date, today) } else { XCTFail("Today should stay a day section") }
        if case .empty(let start, let end) = sections[1] {
            XCTAssertEqual(start, day(1).date)
            XCTAssertEqual(end, day(2).date)
        } else { XCTFail("Days 1–2 should collapse") }
        if case .day = sections[2] {} else { XCTFail("Busy day should stay") }
        if case .empty(let start, let end) = sections[3] { XCTAssertEqual(start, end) } else { XCTFail("Trailing empty day should collapse") }
    }
}
