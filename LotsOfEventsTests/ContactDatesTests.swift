import XCTest
@testable import LotsOfEvents

final class ContactDatesTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    private func record(month: Int, day: Int, year: Int? = nil, birthday: Bool = false) -> ContactDateRecord {
        ContactDateRecord(id: "person:date", contactID: "person", name: "Alex", label: "Anniversary", components: DateComponents(year: year, month: month, day: day), birthday: birthday)
    }
    func testYearlessDateRepeatsAcrossNewYear() {
        let r = record(month: 1, day: 1)
        XCTAssertEqual(r.occurrences(in: DateInterval(start: date(2026, 12, 31), end: date(2028, 1, 2)), timeZone: calendar.timeZone), [date(2027, 1, 1), date(2028, 1, 1)])
    }
    func testLeapDateFallsOnFebruary28AndReturnsTo29InLeapYear() {
        let r = record(month: 2, day: 29, year: 2024)
        XCTAssertEqual(r.occurrences(in: DateInterval(start: date(2027, 1, 1), end: date(2029, 1, 1)), timeZone: calendar.timeZone), [date(2027, 2, 28), date(2028, 2, 29)])
    }
    func testRangeIsHalfOpenAndDoesNotShowDatesBeforeOriginalYear() {
        let r = record(month: 10, day: 31, year: 2026)
        XCTAssertTrue(r.occurrences(in: DateInterval(start: date(2025, 1, 1), end: date(2026, 10, 31)), timeZone: calendar.timeZone).isEmpty)
        XCTAssertEqual(r.occurrences(in: DateInterval(start: date(2026, 10, 31), end: date(2026, 11, 1)), timeZone: calendar.timeZone), [date(2026, 10, 31)])
    }
    func testBirthdayDeduplicationKeepsCustomDatesForSameContact() {
        let range = DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1))
        let items = ContactDates.items(in: range, excludingBirthdays: ["person"], records: [record(month: 6, day: 2, birthday: true), record(month: 7, day: 3)])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Alex · Anniversary")
        XCTAssertEqual(items.first?.blocksAvailability, false)
        XCTAssertEqual(items.first?.allDay, true)
    }
    func testDaySwipeRejectsTapsAndVerticalScrolling() {
        XCTAssertNil(CalendarDates.swipeDirection(horizontal: 20, vertical: 0))
        XCTAssertNil(CalendarDates.swipeDirection(horizontal: 70, vertical: 100))
        XCTAssertEqual(CalendarDates.swipeDirection(horizontal: -100, vertical: 15), 1)
        XCTAssertEqual(CalendarDates.swipeDirection(horizontal: 100, vertical: 15), -1)
    }
}
