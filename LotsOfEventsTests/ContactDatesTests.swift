import XCTest
@testable import LotsOfEvents

final class ContactDatesTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    private func record(month: Int, day: Int, year: Int? = nil, birthday: Bool = false) -> ContactDateRecord {
        ContactDateRecord(id: "person:date", contactID: "person", name: "Alex", label: "Anniversary", components: DateComponents(year: year, month: month, day: day), birthday: birthday)
    }
    func testContactDateIconsDistinguishBirthdaysAnniversariesAndOtherDates() {
        XCTAssertEqual(record(month: 1, day: 1, birthday: true).symbol, "gift.fill")
        XCTAssertEqual(record(month: 1, day: 1).symbol, "heart.fill")
        let custom = ContactDateRecord(id: "custom", contactID: "person", name: "Alex", label: "Graduation",
            components: DateComponents(month: 6, day: 1), birthday: false)
        XCTAssertEqual(custom.symbol, "calendar")
        let items = ContactDates.items(in: DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1)), records: [custom])
        XCTAssertEqual(items.first?.dateSymbol, "calendar")
    }
    func testCombinedSettingMigratesAndTemporarilyHidesAppleBirthdays() {
        let name = "ContactDatesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "birthdayAges")
        ContactDates.migrateSettings(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: ContactDates.enabledKey))
        XCTAssertNil(defaults.object(forKey: "birthdayAges"))
        defaults.set(["birthdays"], forKey: ContactDates.birthdayCalendarIDsKey)
        XCTAssertFalse(Preferences.selected("birthdays", reminders: false, in: defaults))
        XCTAssertTrue(Preferences.selected("work", reminders: false, in: defaults))
        XCTAssertTrue(Preferences.selected("birthdays", reminders: true, in: defaults))
        defaults.set(false, forKey: ContactDates.enabledKey)
        ContactDates.migrateSettings(in: defaults)
        XCTAssertTrue(Preferences.selected("birthdays", reminders: false, in: defaults))
        defaults.set(["birthdays"], forKey: "hiddenCalendars")
        defaults.set(true, forKey: ContactDates.enabledKey)
        defaults.set(false, forKey: ContactDates.enabledKey)
        XCTAssertFalse(Preferences.selected("birthdays", reminders: false, in: defaults))
    }
    func testWidgetTimeoutsAreIndependentAcrossLayouts() {
        let name = "WidgetTimeoutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = date(2026, 11, 1)
        defaults.set(now.timeIntervalSince1970, forKey: "agendaPagedOn")
        defaults.set(now.addingTimeInterval(20).timeIntervalSince1970, forKey: "FocusList.interactedAt")
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now.addingTimeInterval(30), key: "agendaPagedOn", in: defaults))
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(30), key: "FocusList.interactedAt", in: defaults))
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now.addingTimeInterval(50), key: "FocusList.interactedAt", in: defaults))
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now, key: "MonthAgenda.interactedAt", in: defaults))
    }
    func testWidgetDayNavigationExpiresAndRestartsAfterInteraction() {
        let name = "WidgetNavigationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = date(2026, 11, 1)
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now, in: defaults))
        WidgetDayNavigation.select(day: date(2026, 11, 3), now: now, in: defaults)
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(29), in: defaults))
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now.addingTimeInterval(30), in: defaults))
        WidgetDayNavigation.page(2, now: now.addingTimeInterval(20), in: defaults)
        XCTAssertEqual(WidgetDayNavigation.resetDate(in: defaults), now.addingTimeInterval(50))
        XCTAssertEqual(defaults.double(forKey: "selectedWidgetDay"), date(2026, 11, 3).timeIntervalSince1970)
        WidgetDayNavigation.page(1, now: now.addingTimeInterval(51), in: defaults)
        XCTAssertEqual(defaults.double(forKey: "selectedWidgetDay"), Calendar.current.startOfDay(for: now.addingTimeInterval(51)).timeIntervalSince1970)
        XCTAssertEqual(defaults.integer(forKey: "dayWidgetPage"), 1)
    }
    func testYearsAppearForEachOccurrence() {
        let r = record(month: 6, day: 1, year: 2020)
        let items = ContactDates.items(in: DateInterval(start: date(2026, 1, 1), end: date(2028, 1, 1)), records: [r])
        XCTAssertEqual(items.map(\.title), ["Alex · Anniversary · 6 years", "Alex · Anniversary · 7 years"])
        XCTAssertEqual(r.title(on: date(2021, 6, 1), timeZone: calendar.timeZone), "Alex · Anniversary · 1 year")
        XCTAssertEqual(r.title(on: date(2020, 6, 1), timeZone: calendar.timeZone), r.title)
        XCTAssertEqual(record(month: 6, day: 1).title(on: date(2026, 6, 1)), "Alex · Anniversary")
        XCTAssertEqual(record(month: 2, day: 29, year: 2024).title(on: date(2027, 2, 28), timeZone: calendar.timeZone), "Alex · Anniversary · 3 years")
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
