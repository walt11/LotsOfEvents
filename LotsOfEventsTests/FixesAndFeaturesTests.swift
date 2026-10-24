import XCTest
import EventKit
@testable import LotsOfEvents

final class FixesAndFeaturesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testCalendarsAddedAfterAnEditAreShownByDefault() {
        let store = makeDefaults()
        Preferences.setSelected("work", enabled: false, reminders: false, available: ["home", "work"], in: store)
        XCTAssertTrue(Preferences.selected("home", reminders: false, in: store))
        XCTAssertFalse(Preferences.selected("work", reminders: false, in: store))
        XCTAssertTrue(Preferences.selected("new-calendar", reminders: false, in: store))
    }
    func testLegacyCalendarSelectionMigratesToExclusions() {
        let store = makeDefaults()
        store.set(["home"], forKey: "calendars")
        XCTAssertFalse(Preferences.selected("work", reminders: false, in: store))
        Preferences.migrateCalendars(available: ["home", "work"], in: store)
        XCTAssertNil(store.stringArray(forKey: "calendars"))
        XCTAssertTrue(Preferences.selected("home", reminders: false, in: store))
        XCTAssertFalse(Preferences.selected("work", reminders: false, in: store))
        XCTAssertTrue(Preferences.selected("later", reminders: false, in: store))
    }
    func testReminderListsRemainOptIn() {
        let store = makeDefaults()
        XCTAssertFalse(Preferences.selected("list", reminders: true, in: store))
        Preferences.setSelected("list", enabled: true, reminders: true, available: ["list"], in: store)
        XCTAssertTrue(Preferences.selected("list", reminders: true, in: store))
        XCTAssertFalse(Preferences.selected("other", reminders: true, in: store))
    }
    func testMultiDayEventRepeatsUnderEachDayWithUniqueIDs() {
        var trip = AgendaItem(id: "trip", title: "Trip", date: date(24), allDay: true, reminder: false, source: "", color: .blue)
        trip.eventStartDate = date(24)
        trip.endDate = date(27)
        let rows = WidgetAgendaLayout.byDay([trip], start: date(24, hour: 9), days: 5, calendar: calendar)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(rows.map { calendar.component(.day, from: $0.date) }, [24, 25, 26])
        XCTAssertEqual(rows.dropFirst().map(\.sourceID), ["trip", "trip"])
    }
    func testOvernightEventContinuationShowsEndTime() {
        var flight = AgendaItem(id: "flight", title: "Flight", date: date(24, hour: 22), allDay: false, reminder: false, source: "", color: .blue)
        flight.eventStartDate = date(24, hour: 22)
        flight.endDate = date(25, hour: 6)
        let rows = WidgetAgendaLayout.byDay([flight], start: date(24), days: 2, calendar: calendar)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].continuation)
        XCTAssertTrue(rows[1].timeLabel.hasPrefix("Until"))
        XCTAssertFalse(rows[0].continuation)
    }
    func testNewEventTimeRoundsUpToHalfHour() {
        XCTAssertEqual(date(24, hour: 15, minute: 47).roundedUpToHalfHour(calendar: calendar), date(24, hour: 16))
        XCTAssertEqual(date(24, hour: 15, minute: 5).roundedUpToHalfHour(calendar: calendar), date(24, hour: 15, minute: 30))
        XCTAssertEqual(date(24, hour: 15).roundedUpToHalfHour(calendar: calendar), date(24, hour: 15))
    }
    func testOverlappingEventsShareColumns() {
        let spans = [DateInterval(start: date(24, hour: 9), end: date(24, hour: 11)),
                     DateInterval(start: date(24, hour: 10), end: date(24, hour: 12)),
                     DateInterval(start: date(24, hour: 11), end: date(24, hour: 12)),
                     DateInterval(start: date(24, hour: 14), end: date(24, hour: 15))]
        let layout = CalendarDates.columns(spans)
        XCTAssertEqual(layout.map(\.column), [0, 1, 0, 0])
        XCTAssertEqual(layout.map(\.count), [2, 2, 2, 1])
    }
    func testPriorityMatchesAppleRanges() {
        XCTAssertEqual([0, 1, 4, 5, 6, 9].map(ReminderPriority.normalized), [0, 1, 1, 5, 9, 9])
        XCTAssertEqual(ReminderPriority.badge(6), "!")
        XCTAssertEqual(ReminderPriority.badge(5), "!!")
    }
    func testQuickAddParsesTitleAndTime() {
        let parsed = QuickAddParser.parse("Lunch with Sam tomorrow at 1pm")
        XCTAssertEqual(parsed.title, "Lunch with Sam")
        XCTAssertFalse(parsed.allDay)
        let due = try! XCTUnwrap(parsed.date)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(due))
        XCTAssertEqual(Calendar.current.component(.hour, from: due), 13)
    }
    func testQuickAddDayWithoutTimeIsAllDay() {
        let parsed = QuickAddParser.parse("Dentist tomorrow")
        XCTAssertEqual(parsed.title, "Dentist")
        XCTAssertTrue(parsed.allDay)
        XCTAssertEqual(parsed.date, Calendar.current.startOfDay(for: parsed.date!))
    }
    func testQuickAddWithoutDateKeepsWholeTitle() {
        XCTAssertEqual(QuickAddParser.parse("  Buy milk ").title, "Buy milk")
        XCTAssertNil(QuickAddParser.parse("Buy milk").date)
    }

    /// Runs only where Reminders access has been granted (e.g. `simctl privacy grant reminders`).
    func testCompletingRepeatingReminderAdvancesToNextOccurrence() async throws {
        try XCTSkipUnless(EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Needs Reminders access")
        let store = EKEventStore()
        let list = try XCTUnwrap(store.defaultCalendarForNewReminders())
        let reminder = EKReminder(eventStore: store)
        reminder.title = "LotsOfEvents test \(UUID().uuidString)"
        reminder.calendar = list
        let today = Calendar.current.startOfDay(for: .now)
        reminder.dueDateComponents = ReminderDates.components(today, timed: false)
        reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        try store.save(reminder, commit: true)
        let predicate = store.predicateForReminders(in: [list])
        defer {
            store.fetchReminders(matching: predicate) { all in
                for item in all ?? [] where item.title == reminder.title { try? store.remove(item, commit: false) }
                try? store.commit()
            }
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        let matches = await store.reminders(matching: predicate).filter { $0.title == reminder.title }
        let open = matches.filter { !$0.isCompleted }
        XCTAssertEqual(open.count, 1, "Expected the series to continue with one incomplete occurrence")
        XCTAssertEqual(open.first.flatMap(ReminderDates.due), Calendar.current.date(byAdding: .day, value: 1, to: today))
    }
}

final class QuickAddShortcutTests: XCTestCase {
    func testWeekendShortcutMeansTodayOnWeekendsOtherwiseSaturday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10))!
        XCTAssertEqual(QuickAddShortcuts.days(now: saturday, calendar: calendar)[2].phrase, "today")
        XCTAssertEqual(QuickAddShortcuts.days(now: tuesday, calendar: calendar)[2].phrase, "Saturday")
    }
    func testShortcutPhrasesParseAsDates() {
        let parsed = QuickAddParser.parse("Lunch tomorrow 12pm")
        XCTAssertEqual(parsed.title, "Lunch")
        XCTAssertFalse(parsed.allDay)
        XCTAssertEqual(parsed.date.map { Calendar.current.component(.hour, from: $0) }, 12)
        XCTAssertTrue(QuickAddParser.parse("Plan trip next Monday").allDay)
    }
    func testAgendaDetailPrefersLocationThenDuration() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var event = AgendaItem(id: "e", title: "Sync", date: start, allDay: false, reminder: false, source: "Work", color: .blue)
        event.eventStartDate = start
        event.endDate = start.addingTimeInterval(5400)
        XCTAssertEqual(event.agendaDetail, Duration.seconds(5400).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        event.location = "Room 4"
        XCTAssertEqual(event.agendaDetail, "Room 4")
        let reminder = AgendaItem(id: "r", title: "Call", date: start, allDay: true, reminder: true, source: "Personal", color: .blue)
        XCTAssertEqual(reminder.agendaDetail, "Personal")
    }
}
