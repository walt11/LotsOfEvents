import XCTest
import EventKit
@testable import LotsOfEvents

final class ICSImportTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTimedEventInANamedTimeZoneWithFoldedNotesAndAlert() {
        let text = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VTIMEZONE\r
        TZID:America/New_York\r
        BEGIN:STANDARD\r
        DTSTART:19701101T020000\r
        END:STANDARD\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        UID:abc@example.com\r
        SUMMARY:Design review\\, round 2\r
        DTSTART;TZID=America/New_York:20261029T090000\r
        DTEND;TZID=America/New_York:20261029T103000\r
        LOCATION:Room 4\r
        DESCRIPTION:Bring the mockups.\\nJoin at https://zoom.us/j/1\r
         23\r
        BEGIN:VALARM\r
        TRIGGER:-PT15M\r
        DESCRIPTION:Reminder\r
        END:VALARM\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let events = ICSParser.parse(text, defaultZone: chicago)
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.title, "Design review, round 2")
        XCTAssertEqual(event.start, date(2026, 10, 29, 9, zone: TimeZone(identifier: "America/New_York")!))
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 5400)
        XCTAssertFalse(event.allDay)
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.notes, "Bring the mockups.\nJoin at https://zoom.us/j/123")
        XCTAssertEqual(event.alertOffsets, [-900])
    }

    func testUTCAllDayDurationAndDefaults() {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Launch
        DTSTART:20261030T150000Z
        DURATION:PT45M
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Conference
        DTSTART;VALUE=DATE:20261102
        DTEND;VALUE=DATE:20261105
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20261225
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Cancelled
        STATUS:CANCELLED
        DTSTART:20261030T150000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(text, defaultZone: chicago)
        XCTAssertEqual(events.map(\.title), ["Launch", "Conference", "New Event"])
        XCTAssertEqual(events[0].start, date(2026, 10, 30, 15, zone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(events[0].end.timeIntervalSince(events[0].start), 2700)
        XCTAssertTrue(events[1].allDay)
        XCTAssertEqual(events[1].start, date(2026, 11, 2, zone: chicago))
        XCTAssertEqual(events[1].end, date(2026, 11, 5, zone: chicago))
        XCTAssertTrue(events[2].allDay)
        XCTAssertEqual(events[2].end.timeIntervalSince(events[2].start), 86_400)
    }

    func testOutlookWindowsTimeZoneAndChangedOccurrence() {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:series
        SUMMARY:Standup
        DTSTART;TZID="Pacific Standard Time":20261026T093000
        DTEND;TZID="Pacific Standard Time":20261026T094500
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261231T000000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:series
        RECURRENCE-ID;TZID="Pacific Standard Time":20261028T093000
        SUMMARY:Standup (moved)
        DTSTART;TZID="Pacific Standard Time":20261028T110000
        DTEND;TZID="Pacific Standard Time":20261028T111500
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(text, defaultZone: chicago)
        XCTAssertEqual(events.map(\.title), ["Standup"])
        XCTAssertNil(events[0].importIssue)
        XCTAssertEqual(events[0].overrides.map(\.title), ["Standup (moved)"])
        XCTAssertEqual(events[0].timeZone?.identifier, "America/Los_Angeles")
        XCTAssertEqual(events[0].start, date(2026, 10, 26, 9, 30, zone: TimeZone(identifier: "America/Los_Angeles")!))
        XCTAssertEqual(events[0].recurrence, "FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261231T000000Z")
    }

    func testRecurrenceRules() {
        let weekly = ICSParser.recurrenceRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10")
        XCTAssertEqual(weekly?.frequency, .weekly)
        XCTAssertEqual(weekly?.interval, 2)
        XCTAssertEqual(weekly?.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .wednesday])
        XCTAssertEqual(weekly?.recurrenceEnd?.occurrenceCount, 10)
        let lastFriday = ICSParser.recurrenceRule("FREQ=MONTHLY;BYDAY=-1FR")
        XCTAssertEqual(lastFriday?.daysOfTheWeek?.first?.weekNumber, -1)
        XCTAssertNil(lastFriday?.recurrenceEnd)
        XCTAssertNil(ICSParser.recurrenceRule("FREQ=HOURLY"))
    }

    func testDurations() {
        XCTAssertEqual(ICSParser.duration("-PT15M"), -900)
        XCTAssertEqual(ICSParser.duration("P1DT2H"), 93_600)
        XCTAssertEqual(ICSParser.duration("P1W"), 604_800)
        XCTAssertNil(ICSParser.duration("15M"))
    }
}


extension ICSImportTests {
    func testMalformedDatesAreRejectedWithoutCrashing() {
        for value in ["20261029T09", "20261029T0900", "20261329T090000", "20260230", "20261029T250000", "20261029T090000garbage"] {
            XCTAssertNil(ICSParser.date(value, params: [:], zone: chicago), value)
            XCTAssertTrue(ICSParser.parse("BEGIN:VEVENT\nDTSTART:\(value)\nEND:VEVENT").isEmpty)
        }
    }

    func testExcludedAddedAndCancelledOccurrencesAreKeptWithTheirSeries() {
        let excluded = ICSParser.parse("BEGIN:VEVENT\nUID:series\nDTSTART:20261101T090000Z\nRRULE:FREQ=DAILY\nEXDATE:20261102T090000Z,20261104T090000Z\nEND:VEVENT")
        XCTAssertEqual(excluded.first?.excludedDates.count, 2)
        XCTAssertNil(excluded.first?.importIssue)
        let added = ICSParser.parse("BEGIN:VEVENT\nUID:series\nDTSTART:20261101T090000Z\nRRULE:FREQ=DAILY\nRDATE:20261203T090000Z\nEND:VEVENT")
        XCTAssertEqual(added.first?.additionalDates.count, 1)
        XCTAssertNil(added.first?.importIssue)
        XCTAssertNotNil(ICSParser.parse("BEGIN:VEVENT\nUID:series\nDTSTART:20261101T090000Z\nRRULE:FREQ=DAILY\nRDATE;VALUE=PERIOD:20261203T090000Z/PT1H\nEND:VEVENT").first?.importIssue)
        let text = "BEGIN:VEVENT\nUID:series\nDTSTART:20261101T090000Z\nRRULE:FREQ=DAILY\nEND:VEVENT\nBEGIN:VEVENT\nUID:series\nRECURRENCE-ID:20261102T090000Z\nSTATUS:CANCELLED\nEND:VEVENT"
        let cancelled = ICSParser.parse(text)
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertNil(cancelled.first?.importIssue)
        XCTAssertEqual(cancelled.first?.overrides.first?.cancelled, true)
        let single = ICSParser.parse("BEGIN:VEVENT\nUID:lone\nRECURRENCE-ID:20261102T090000Z\nDTSTART:20261102T100000Z\nDTEND:20261102T110000Z\nSUMMARY:Moved\nEND:VEVENT")
        XCTAssertEqual(single.map(\.title), ["Moved"])
        XCTAssertNil(single.first?.importIssue)
        let ordinary = ICSParser.parse("BEGIN:VEVENT\nDTSTART:20261101T090000Z\nRRULE:FREQ=DAILY;COUNT=3\nEND:VEVENT")
        XCTAssertEqual(ordinary.count, 1)
        XCTAssertNil(ordinary.first?.importIssue)
    }

    func testInvalidAndUnsupportedRecurrencesCannotBecomeOneOffEvents() {
        for rule in ["FREQ=HOURLY", "FREQ=DAILY;COUNT=-1", "FREQ=MONTHLY;BYMONTHDAY=99", "FREQ=DAILY;BYHOUR=9,11", "FREQ=DAILY;UNTIL=20261029T09"] {
            XCTAssertNil(ICSParser.recurrenceRule(rule))
            let events = ICSParser.parse("BEGIN:VEVENT\nDTSTART:20261101T090000Z\nRRULE:\(rule)\nEND:VEVENT")
            XCTAssertNotNil(events.first?.importIssue)
        }
    }

    /// Runs where Calendar access is granted (e.g. `simctl privacy grant calendar`); cleans up after itself.
    func testSavingASeriesAppliesItsExceptions() throws {
        try XCTSkipUnless(EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Needs Calendar access")
        let store = EKEventStore()
        let calendar = try XCTUnwrap(store.defaultCalendarForNewEvents)
        let uid = "test-\(UUID().uuidString)"
        let text = "BEGIN:VEVENT\nUID:\(uid)\nSUMMARY:\(uid)\nDTSTART:20300107T150000Z\nDTEND:20300107T160000Z\nRRULE:FREQ=DAILY;COUNT=5\nEXDATE:20300108T150000Z\nRDATE:20300120T150000Z\nEND:VEVENT\nBEGIN:VEVENT\nUID:\(uid)\nRECURRENCE-ID:20300109T150000Z\nSUMMARY:\(uid) moved\nDTSTART:20300109T180000Z\nDTEND:20300109T190000Z\nEND:VEVENT\nBEGIN:VEVENT\nUID:\(uid)\nRECURRENCE-ID:20300110T150000Z\nSTATUS:CANCELLED\nEND:VEVENT"
        try ICSImporter.save(ICSParser.parse(text), calendarID: calendar.calendarIdentifier)
        let start = Date(timeIntervalSince1970: 1_893_888_000) // Jan 6, 2030
        let found = EKEventStore().events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(30 * 86400), calendars: [calendar]))
            .filter { ($0.title ?? "").hasPrefix(uid) }.sorted { $0.startDate < $1.startDate }
        defer { let cleanup = EKEventStore(); for event in found { if let item = cleanup.event(withIdentifier: event.eventIdentifier) { try? cleanup.remove(item, span: .futureEvents, commit: true) } } }
        XCTAssertEqual(found.count, 4, "Jan 7, moved Jan 9, Jan 11, and the added Jan 20")
        XCTAssertEqual(found.filter { $0.title == "\(uid) moved" }.count, 1)
    }

    func testWeekStartFromGoogleAndOutlookDoesNotBlockARepeat() {
        let rule = ICSParser.recurrenceRule("FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE;INTERVAL=1")
        XCTAssertEqual(rule?.daysOfTheWeek?.map(\.dayOfTheWeek), [.monday, .wednesday])
        let events = ICSParser.parse("BEGIN:VEVENT\nDTSTART:20261102T150000Z\nRRULE:FREQ=WEEKLY;WKST=MO;BYDAY=MO\nEND:VEVENT")
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.importIssue)
    }
}
