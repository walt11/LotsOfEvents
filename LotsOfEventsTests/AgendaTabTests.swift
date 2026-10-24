import XCTest
@testable import LotsOfEvents

final class AgendaTabTests: XCTestCase {
    func testReselectingAgendaOrCalendarReturnsToToday() {
        XCTAssertTrue(TabReselect.returnsToToday(selecting: 0, from: 0))
        XCTAssertTrue(TabReselect.returnsToToday(selecting: 1, from: 1))
        XCTAssertFalse(TabReselect.returnsToToday(selecting: 0, from: 1))
        XCTAssertFalse(TabReselect.returnsToToday(selecting: 2, from: 2))
        XCTAssertFalse(TabReselect.returnsToToday(selecting: 3, from: 3))
    }
}
