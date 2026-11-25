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
    func testReminderListsShownByDefaultAndKeepOlderChoices() {
        let store = makeDefaults()
        XCTAssertTrue(Preferences.selected("list", reminders: true, in: store))
        Preferences.setSelected("list", enabled: false, reminders: true, available: ["list", "other"], in: store)
        XCTAssertFalse(Preferences.selected("list", reminders: true, in: store))
        XCTAssertTrue(Preferences.selected("other", reminders: true, in: store))
        XCTAssertTrue(Preferences.selected("added-later", reminders: true, in: store))
        // An older explicit choice still applies until it's converted.
        let old = makeDefaults()
        old.set(["chosen"], forKey: "reminderLists")
        XCTAssertFalse(Preferences.selected("other", reminders: true, in: old))
        Preferences.migrate(reminders: true, available: ["chosen", "other"], in: old)
        XCTAssertTrue(Preferences.selected("chosen", reminders: true, in: old))
        XCTAssertFalse(Preferences.selected("other", reminders: true, in: old))
        XCTAssertTrue(Preferences.selected("added-later", reminders: true, in: old))
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

final class CustomWidgetStyleTests: XCTestCase {
    func testStyleRoundTripsThroughJSON() throws {
        var style = CustomWidgetStyle()
        style.fill = .solid
        style.first = StoredColor(red: 0.9, green: 0.2, blue: 0.1)
        style.borderWidth = 2.5
        style.borderColor = StoredColor(red: 1, green: 1, blue: 1, opacity: 0.4)
        style.direction = .across
        let decoded = try JSONDecoder().decode(CustomWidgetStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded, style)
    }
    func testTextColorStaysReadable() {
        var style = CustomWidgetStyle()
        style.fill = .solid
        style.first = StoredColor(red: 0.98, green: 0.95, blue: 0.7)
        XCTAssertEqual(style.text, .black)
        style.first = StoredColor(red: 0.1, green: 0.1, blue: 0.3)
        XCTAssertEqual(style.text, .white)
        style.fill = .gradient
        style.second = StoredColor(red: 0.2, green: 0.2, blue: 0.5)
        XCTAssertEqual(style.text, .white)
    }
}

final class CustomAccentTests: XCTestCase {
    func testStylesSavedBeforeAccentExistedStillDecode() throws {
        let old = #"{"fill":"Solid","first":{"red":0.1,"green":0.2,"blue":0.3,"opacity":1},"second":{"red":0,"green":0,"blue":0,"opacity":1},"direction":"Top to bottom","borderWidth":0,"borderColor":{"red":1,"green":1,"blue":1,"opacity":1}}"#
        let style = try JSONDecoder().decode(CustomWidgetStyle.self, from: Data(old.utf8))
        XCTAssertNil(style.accent)
        XCTAssertEqual(style.fill, .solid)
    }
    func testAccentTextContrast() {
        XCTAssertEqual(CustomWidgetStyle.contrastingText(on: StoredColor(red: 1, green: 0.85, blue: 0.2)), .black)
        XCTAssertEqual(CustomWidgetStyle.contrastingText(on: StoredColor(red: 0.1, green: 0.1, blue: 0.4)), .white)
    }
}

final class ReminderFocusTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func testTodayBuckets() {
        let now = date(26, 13)
        XCTAssertEqual(FocusGrouping.bucket(due: date(25), timed: false, now: now, calendar: calendar), .overdue)
        XCTAssertEqual(FocusGrouping.bucket(due: date(26, 9), timed: true, now: now, calendar: calendar), .overdue)
        XCTAssertEqual(FocusGrouping.bucket(due: date(26, 15), timed: true, now: now, calendar: calendar), .afternoon)
        XCTAssertEqual(FocusGrouping.bucket(due: date(26, 19), timed: true, now: now, calendar: calendar), .tonight)
        XCTAssertEqual(FocusGrouping.bucket(due: date(26), timed: false, now: now, calendar: calendar), .anytime)
        XCTAssertNil(FocusGrouping.bucket(due: date(27, 8), timed: true, now: now, calendar: calendar))
        XCTAssertNil(FocusGrouping.bucket(due: nil, timed: false, now: now, calendar: calendar))
        XCTAssertEqual(FocusGrouping.bucket(due: date(26, 10), timed: true, now: date(26, 8), calendar: calendar), .morning)
    }
    func testProgress() {
        XCTAssertEqual(FocusGrouping.progress(done: 3, open: 5), 0.375)
        XCTAssertEqual(FocusGrouping.progress(done: 0, open: 0), 0)
    }
    func testDueLabels() {
        let now = date(26, 13)
        XCTAssertEqual(ReminderDueText.label(due: date(26), timed: false, now: now, calendar: calendar), "Today")
        XCTAssertEqual(ReminderDueText.label(due: date(25), timed: false, now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(ReminderDueText.label(due: date(27), timed: false, now: now, calendar: calendar), "Tomorrow")
        XCTAssertTrue(ReminderDueText.label(due: date(27, 9), timed: true, now: now, calendar: calendar).hasPrefix("Tomorrow "))
    }
}

final class NewListTests: XCTestCase {
    /// Runs where Reminders access is granted (e.g. `simctl privacy grant reminders`); cleans up after itself.
    @MainActor
    func testCreateListAddsWritableReminderList() async throws {
        try XCTSkipUnless(EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Needs Reminders access")
        let model = AgendaModel()
        await model.refresh()
        let source = try XCTUnwrap(model.store.defaultCalendarForNewReminders()?.source)
        let name = "LotsOfEvents test \(UUID().uuidString.prefix(6))"
        let id = try model.createList(named: name, color: ListColors.presets[1].color, in: source)
        defer { if let list = model.store.calendar(withIdentifier: id) { try? model.store.removeCalendar(list, commit: true) } }
        let list = try XCTUnwrap(model.store.calendar(withIdentifier: id))
        XCTAssertEqual(list.title, name)
        XCTAssertEqual(list.allowedEntityTypes, .reminder)
        XCTAssertTrue(model.lists.contains { $0.calendarIdentifier == id })
    }
}

final class InlineReminderDraftTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func testTypedDateUsedWhenNoMenuChoice() {
        let r = InlineReminderDraft().resolve("Pay rent", now: date(26, 10), calendar: calendar)
        XCTAssertEqual(r.title, "Pay rent")
        XCTAssertNil(r.due)
    }
    func testMenuDayAndTime() {
        var draft = InlineReminderDraft()
        draft.day = .tomorrow
        draft.time = DateComponents(hour: 9, minute: 0)
        let r = draft.resolve("Call bank", now: date(26, 10), calendar: calendar)
        XCTAssertEqual(r.due, date(27, 9))
        XCTAssertTrue(r.timed)
    }
    func testWeekendAndNextWeek() {
        var draft = InlineReminderDraft()
        draft.day = .weekend
        // Monday Oct 26 → Saturday Oct 31; Saturday stays today.
        XCTAssertEqual(draft.resolve("x", now: date(26, 10), calendar: calendar).due, date(31))
        XCTAssertEqual(draft.resolve("x", now: date(31, 10), calendar: calendar).due, date(31))
        draft.day = .nextWeek
        // Monday Oct 26 → the following Monday, Nov 2.
        XCTAssertEqual(draft.resolve("x", now: date(26, 10), calendar: calendar).due, calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
    }
    func testTimeWithoutDayRollsToNextOccurrence() {
        var draft = InlineReminderDraft()
        draft.time = DateComponents(hour: 9, minute: 0)
        XCTAssertEqual(draft.resolve("x", now: date(26, 10), calendar: calendar).due, date(27, 9))
        XCTAssertEqual(draft.resolve("x", now: date(26, 8), calendar: calendar).due, date(26, 9))
    }
}

final class ReminderOrderTests: XCTestCase {
    func testUndatedKeepAddedOrderAfterDated() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        typealias Item = (title: String, due: Date?, created: Date)
        let items: [Item] = [
            ("Zebra notes", nil, t0),
            ("Apple pie", nil, t0.addingTimeInterval(60)),
            ("Dentist", t0.addingTimeInterval(86400), t0.addingTimeInterval(120)),
            ("Book flights", nil, t0.addingTimeInterval(180))
        ]
        let ordered = items.sorted {
            ReminderOrder.precedes(due: $0.due, priority: 0, created: $0.created, title: $0.title,
                                   before: $1.due, 0, $1.created, $1.title, byPriority: false)
        }.map(\.title)
        XCTAssertEqual(ordered, ["Dentist", "Zebra notes", "Apple pie", "Book flights"])
    }
    func testPrioritySortStillWins() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ReminderOrder.precedes(due: nil, priority: 1, created: t0.addingTimeInterval(60), title: "B",
                                             before: nil, 0, t0, "A", byPriority: true))
    }
}

final class AppThemeTests: XCTestCase {
    private func contrast(_ a: UInt, _ b: UInt) -> Double {
        func lum(_ h: UInt) -> Double {
            [Double((h >> 16) & 255), Double((h >> 8) & 255), Double(h & 255)].map { v -> Double in
                let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }.enumerated().map { [0.2126, 0.7152, 0.0722][$0.offset] * $0.element }.reduce(0, +)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// The six preset themes; Custom is the user's own colors, and its editor warns about low contrast instead.
    func testSixThemesAllReadable() {
        let presets = AppTheme.allCases.filter { $0 != .custom }
        XCTAssertEqual(presets.count, 6)
        for theme in presets {
            let c = theme.colors
            for (fg, bg, name) in [(c.ink, c.card, "ink/card"), (c.muted, c.card, "muted/card"), (c.muted, c.paper, "muted/paper"),
                                   (c.accent, c.card, "accent/card"), (c.accent, c.paper, "accent/paper"), (c.onAccent, c.accent, "onAccent")] {
                XCTAssertGreaterThanOrEqual(contrast(fg, bg), 4.5, "\(theme.title) \(name)")
            }
        }
    }
}

final class ThemeIconTests: XCTestCase {
    func testEveryThemeHasABundledIcon() throws {
        XCTAssertNil(AppTheme.graphite.iconName)
        let alternates = (Bundle(for: AgendaModel.self).object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundleAlternateIcons"] as? [String: Any]
        // Custom keeps whichever icon is already set.
        XCTAssertNil(AppTheme.custom.iconName)
        for theme in AppTheme.allCases where theme != .graphite && theme != .custom {
            let name = try XCTUnwrap(theme.iconName)
            XCTAssertNotNil(alternates?[name], "\(name) missing from the app's alternate icons")
        }
    }
}

final class QuickAddDayTests: XCTestCase {
    func testNamesDay() {
        XCTAssertTrue(QuickAddParser.namesDay("Lunch Friday 1pm"))
        XCTAssertTrue(QuickAddParser.namesDay("call tomorrow"))
        XCTAssertTrue(QuickAddParser.namesDay("Dentist Oct 30"))
        XCTAssertFalse(QuickAddParser.namesDay("Call mom 3pm"))
        XCTAssertFalse(QuickAddParser.namesDay("Buy milk"))
    }
}

final class AlertDefaultsTests: XCTestCase {
    func testEventOffsets() {
        XCTAssertEqual(AlertDefaults.eventOffset(allDay: false, timed: .minutes15, allDayOption: .none), -900)
        XCTAssertEqual(AlertDefaults.eventOffset(allDay: false, timed: .atTime, allDayOption: .none), 0)
        XCTAssertNil(AlertDefaults.eventOffset(allDay: false, timed: .none, allDayOption: .dayOf))
        // All-day alerts count from midnight: 9 AM that day, or 9 AM the day before.
        XCTAssertEqual(AlertDefaults.eventOffset(allDay: true, timed: .none, allDayOption: .dayOf, allDayMinute: 540), 32_400)
        XCTAssertEqual(AlertDefaults.eventOffset(allDay: true, timed: .none, allDayOption: .dayBefore, allDayMinute: 540), -54_000)
        XCTAssertNil(AlertDefaults.eventOffset(allDay: true, timed: .minutes15, allDayOption: .none))
        // A custom time: 7:30 AM the day before.
        XCTAssertEqual(AlertDefaults.eventOffset(allDay: true, timed: .none, allDayOption: .dayBefore, allDayMinute: 450), -86_400 + 27_000)
    }
    func testReminderAlarmDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
        XCTAssertEqual(AlertDefaults.reminderAlarmDate(due: due, timed: true, option: .minutes30, dateOnly: false, calendar: calendar), due.addingTimeInterval(-1800))
        XCTAssertNil(AlertDefaults.reminderAlarmDate(due: due, timed: true, option: .none, dateOnly: true, calendar: calendar))
        XCTAssertNil(AlertDefaults.reminderAlarmDate(due: due, timed: false, option: .atTime, dateOnly: false, calendar: calendar))
        XCTAssertEqual(AlertDefaults.reminderAlarmDate(due: due, timed: false, option: .atTime, dateOnly: true, dateOnlyMinute: 510, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 8, minute: 30)))
    }
    func testApplySkipsEventsThatAlreadyHaveAlerts() {
        let event = EKEvent(eventStore: EKEventStore())
        event.isAllDay = false
        let existing = EKAlarm(relativeOffset: -60)
        event.addAlarm(existing)
        AlertDefaults.apply(to: event)
        XCTAssertEqual(event.alarms?.count, 1)
    }
}

final class ReviewFeatureTests: XCTestCase {
    func testRepeatPhrases() {
        let gym = QuickAddParser.parse("Gym every Monday 6pm")
        XCTAssertEqual(gym.title, "Gym")
        XCTAssertEqual(gym.repeats, QuickAddRepeat(frequency: .weekly, weekdays: [2]))
        XCTAssertEqual(gym.date.map { Calendar.current.component(.weekday, from: $0) }, 2)
        XCTAssertEqual(gym.date.map { Calendar.current.component(.hour, from: $0) }, 18)
        XCTAssertEqual(QuickAddParser.parse("Take vitamins daily").repeats, QuickAddRepeat(frequency: .daily))
        XCTAssertEqual(QuickAddParser.parse("Standup every weekday 9am").repeats?.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(QuickAddParser.parse("Pay rent every month").repeats?.frequency, .monthly)
        XCTAssertEqual(QuickAddParser.parse("Pay rent every month").title, "Pay rent")
        XCTAssertNil(QuickAddParser.parse("Buy milk").repeats)
    }
    func testDragSnapsToQuarterHoursOnTheClockAndDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 10))!
        func target(_ width: CGFloat, _ height: CGFloat, column: CGFloat? = 48) -> DateComponents {
            calendar.dateComponents([.day, .hour, .minute], from: CalendarDates.dragTarget(start: start, translation: CGSize(width: width, height: height), hourHeight: 52, columnWidth: column, calendar: calendar))
        }
        // 9:10 dragged about 50 minutes lands exactly on 10:00, not 10:10.
        XCTAssertEqual(target(0, 44), DateComponents(day: 27, hour: 10, minute: 0))
        // Picking it up without moving leaves it alone; a real move snaps onto the grid.
        XCTAssertEqual(target(0, 2), DateComponents(day: 27, hour: 9, minute: 10))
        XCTAssertEqual(target(0, 8), DateComponents(day: 27, hour: 9, minute: 15))
        XCTAssertEqual(target(95, 0), DateComponents(day: 29, hour: 9, minute: 15))
        // Day view ignores sideways movement, and the start never leaves its day.
        XCTAssertEqual(target(200, 0, column: nil).day, 27)
        XCTAssertEqual(target(0, -1000), DateComponents(day: 27, hour: 0, minute: 0))
        XCTAssertEqual(target(0, 2000), DateComponents(day: 27, hour: 23, minute: 45))
    }
    func testTodayReminderCountIncludesOverdueOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        func d(_ day: Int, _ hour: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let titles = TodayReminderCounts.dueToday([("Later", d(27, 18)), ("Tomorrow", d(28, 9)), ("Overdue", d(25)), ("Undated", nil)], now: d(27, 10), calendar: calendar)
        XCTAssertEqual(titles, ["Overdue", "Later"])
    }
}

final class TodayTasksTests: XCTestCase {
    func testTodayIncludesDueOverdueAndUndatedFromChosenLists() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        func date(_ day: Int, hour: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let now = date(27, hour: 9), chosen: Set<String> = ["home"]
        func includes(_ due: Date?, list: String = "home", shown: Bool = true) -> Bool {
            TodayTasks.includes(due: due, listID: list, shown: shown, now: now, undatedLists: chosen, calendar: calendar)
        }
        XCTAssertTrue(includes(date(27, hour: 23)), "due later today")
        XCTAssertTrue(includes(date(20)), "overdue")
        XCTAssertFalse(includes(date(28)), "due tomorrow")
        XCTAssertFalse(includes(date(27), shown: false), "dated, from a hidden list")
        XCTAssertTrue(includes(nil), "undated, from a chosen list")
        XCTAssertTrue(includes(nil, shown: false), "undated, from a chosen list hidden elsewhere")
        XCTAssertFalse(includes(nil, list: "work"), "undated, from a list not chosen for Today")
    }
    func testUpcomingIncludesRemindersThroughTheLastDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        func date(_ day: Int, hour: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        func includes(_ due: Date) -> Bool {
            TodayTasks.includes(due: due, listID: "home", shown: true, now: date(27, hour: 9), days: 5, undatedLists: [], calendar: calendar)
        }
        XCTAssertTrue(includes(date(28)), "tomorrow")
        XCTAssertTrue(includes(date(31, hour: 23)), "last day of five")
        XCTAssertFalse(includes(date(32)), "the day after")
        XCTAssertTrue(includes(date(20)), "overdue")
    }
    func testWidgetTaskTrailingLabel() {
        let base = WidgetTask(id: "a", title: "A", due: nil, timed: false, list: "L", color: .blue, writable: true, priority: 0)
        XCTAssertNil(base.trailingLabel)
        XCTAssertEqual(WidgetTask(id: "b", title: "B", due: .now, timed: false, list: "L", color: .blue, writable: true, priority: 0, overdue: true).trailingLabel, "Overdue")
        XCTAssertNotNil(WidgetTask(id: "c", title: "C", due: .now, timed: true, list: "L", color: .blue, writable: true, priority: 0).trailingLabel)
    }
}

final class WidgetFitTests: XCTestCase {
    func testFitsEverythingWhenRoomOrLeavesRoomForMoreLine() {
        XCTAssertEqual(WidgetFit.count([10, 10], in: 20), 2, "exact fit needs no +N more line")
        XCTAssertEqual(WidgetFit.count([10, 10, 10], in: 25), 1, "two rows would leave no room for +N more")
        XCTAssertEqual(WidgetFit.count([10, 10, 10, 10], in: 34), 2)
        XCTAssertEqual(WidgetFit.count([], in: 10), 0)
        XCTAssertEqual(WidgetFit.count([30], in: 10), 0)
    }
}

final class WidgetScrollTests: XCTestCase {
    func testVisibleRowsFromOffset() {
        XCTAssertEqual(WidgetScroll.visible([10, 10, 10, 10], from: 0, in: 25), 2)
        XCTAssertEqual(WidgetScroll.visible([10, 10, 10, 10], from: 3, in: 25), 1)
        XCTAssertEqual(WidgetScroll.visible([10, 10], from: 2, in: 25), 0)
    }
    func testMaxStartIsFirstRowOfLastScreenful() {
        XCTAssertEqual(WidgetScroll.maxStart([10, 10, 10, 10], in: 25), 2)
        XCTAssertEqual(WidgetScroll.maxStart([10, 10], in: 25), 0, "everything fits, so nothing to scroll")
        XCTAssertEqual(WidgetScroll.maxStart([], in: 25), 0)
    }
    func testStepKeepsOneRowForContext() {
        XCTAssertEqual(WidgetScroll.step(visible: 6), 5)
        XCTAssertEqual(WidgetScroll.step(visible: 1), 1)
        XCTAssertEqual(WidgetScroll.step(visible: 0), 1)
    }
}

final class CustomizationTests: XCTestCase {
    func testCustomAppColorsRoundTrip() {
        let key = CustomAppColors.key
        let previous = Preferences.defaults.string(forKey: key)
        defer { Preferences.defaults.set(previous, forKey: key) }
        var colors = CustomAppColors(from: .studio)
        colors.accent = 0x123456
        colors.dark = true
        colors.save()
        XCTAssertEqual(CustomAppColors.saved, colors)
        XCTAssertEqual(AppTheme.custom.scheme, .dark)
        XCTAssertEqual(colors.onAccent, 0xFFFFFF)
    }
    func testUnreadableCustomColorsFallBackToGraphite() {
        let key = CustomAppColors.key
        let previous = Preferences.defaults.string(forKey: key)
        defer { Preferences.defaults.set(previous, forKey: key) }
        Preferences.defaults.set("not,colors", forKey: key)
        XCTAssertEqual(CustomAppColors.saved, CustomAppColors(from: .graphite))
    }
    func testContrast() {
        XCTAssertEqual(CustomAppColors.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(CustomAppColors.contrast(0x777777, 0x777777), 1, accuracy: 0.01)
    }
    func testWidgetLookKeepsDefaultsForMissingKeys() throws {
        let look = try JSONDecoder().decode(WidgetLook.self, from: Data(#"{"density":"Roomy"}"#.utf8))
        XCTAssertEqual(look.density, .roomy)
        XCTAssertEqual(look.textSize, .standard)
        XCTAssertTrue(look.showTimes)
    }
    func testWidgetRowsGrowWithTextAndDensity() {
        var look = WidgetLook()
        XCTAssertEqual(look.row(16), 16)
        look.textSize = .large
        look.density = .roomy
        XCTAssertGreaterThan(look.row(16), 16)
        look.textSize = .small
        look.density = .compact
        XCTAssertLessThan(look.row(16), 16)
    }
    func testTabOrderIgnoresBadValues() {
        XCTAssertEqual(AppTabs.order("2,0,1"), [2, 0, 1])
        XCTAssertEqual(AppTabs.order("2,2,1"), [0, 1, 2])
        XCTAssertEqual(AppTabs.order(""), [0, 1, 2])
        XCTAssertEqual(AppTabs.stored([1, 2, 0]), "1,2,0")
    }
    func testStoredColorHex() {
        XCTAssertEqual(StoredColor(red: 1, green: 0, blue: 0.5).hex, 0xFF0080)
    }
}

final class CalendarFeatureTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }
    func testMeetingLinksFoundInURLLocationOrNotes() {
        let zoom = URL(string: "https://us02web.zoom.us/j/123456")!
        XCTAssertEqual(MeetingLink.url(url: zoom, location: nil, notes: nil), zoom)
        XCTAssertEqual(MeetingLink.url(url: nil, location: "https://meet.google.com/abc-defg-hij", notes: nil)?.host, "meet.google.com")
        XCTAssertEqual(MeetingLink.url(url: URL(string: "https://example.com"), location: "Room 4", notes: "Join: https://teams.microsoft.com/l/meetup-join/xyz thanks")?.host, "teams.microsoft.com")
        XCTAssertNil(MeetingLink.url(url: URL(string: "https://example.com"), location: "Cafe", notes: "See https://notzoom.us.example.org"))
        XCTAssertEqual(MeetingLink.service(zoom), "Zoom")
    }
    func testConflictsOnlyMarkOverlappingEvents() {
        let base = Date(timeIntervalSince1970: 0)
        let ids = Conflicts.ids([("a", base, base + 3600), ("b", base + 1800, base + 5400), ("c", base + 5400, base + 7200), ("d", base + 9000, base + 9000)])
        XCTAssertEqual(ids, ["a", "b"])
    }
    func testSweepAndResizeSnapToQuarterHours() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))!
        // 9:05 to 10:20 at 52 points an hour sweeps 9:00 to 10:15, dragging either way.
        let down = CalendarDates.sweep(day: day, from: 52 * (9 + 5 / 60), to: 52 * (10 + 20 / 60), hourHeight: 52, calendar: calendar)
        let up = CalendarDates.sweep(day: day, from: 52 * (10 + 20 / 60), to: 52 * (9 + 5 / 60), hourHeight: 52, calendar: calendar)
        XCTAssertEqual(down, up)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: down.start), DateComponents(hour: 9, minute: 0))
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: down.end), DateComponents(hour: 10, minute: 15))
        // A touch just before the hour starts on the hour.
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: CalendarDates.sweep(day: day, from: 52 * (8 + 57 / 60), to: 52 * 10, hourHeight: 52, calendar: calendar).start), DateComponents(hour: 9, minute: 0))
        // A hold without a drag still makes a 15-minute event.
        XCTAssertEqual(CalendarDates.sweep(day: day, from: 52 * 9, to: 52 * 9, hourHeight: 52, calendar: calendar).duration, 900)

        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let end = calendar.date(bySettingHour: 10, minute: 10, second: 0, of: day)!
        // Dragging the bottom edge 45 minutes lands on 11:00, and it can't end before 9:15.
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: CalendarDates.resizeTarget(start: start, end: end, translation: 39, hourHeight: 52, calendar: calendar)), DateComponents(hour: 11, minute: 0))
        XCTAssertEqual(CalendarDates.resizeTarget(start: start, end: end, translation: -500, hourHeight: 52, calendar: calendar), start.addingTimeInterval(900))
    }
    func testCalendarSetsApplyAndClear() {
        let store = UserDefaults(suiteName: "CalendarSetTests")!
        store.removePersistentDomain(forName: "CalendarSetTests")
        let work = CalendarSet(name: "Work", hiddenCalendars: ["home"], hiddenLists: ["groceries"])
        CalendarSet.apply(work, in: store)
        XCTAssertFalse(Preferences.selected("home", reminders: false, in: store))
        XCTAssertTrue(Preferences.selected("office", reminders: false, in: store))
        XCTAssertFalse(Preferences.selected("groceries", reminders: true, in: store))
        CalendarSet.apply(nil, in: store)
        XCTAssertTrue(Preferences.selected("home", reminders: false, in: store))
        CalendarSet.activeID = nil
    }
}

@MainActor
final class ReviewRegressionTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Chicago")!
        return result
    }

    func testSweepingUsesClockHoursOnBothDSTTransitions() {
        for (month, day) in [(3, 8), (11, 1)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let range = CalendarDates.sweep(day: date, from: 9 * 52, to: 10 * 52, hourHeight: 52, calendar: calendar)
            XCTAssertEqual(calendar.component(.hour, from: range.start), 9)
            XCTAssertEqual(calendar.component(.hour, from: range.end), 10)
            let midnight = CalendarDates.sweep(day: date, from: 23 * 52, to: 24 * 52, hourHeight: 52, calendar: calendar).end
            XCTAssertEqual(calendar.component(.hour, from: midnight), 0)
            XCTAssertEqual(calendar.component(.day, from: midnight), day + 1)
        }
    }

    func testPickingTimePreservesTypedDay() {
        let text = "Call plumber next Friday"
        let parsed = QuickAddParser.parse(text, calendar: calendar)
        XCTAssertNotNil(parsed.date)
        var draft = InlineReminderDraft()
        draft.time = DateComponents(hour: 9, minute: 0)
        let result = draft.resolve(text, calendar: calendar)
        XCTAssertEqual(result.due.map { calendar.startOfDay(for: $0) }, parsed.date.map { calendar.startOfDay(for: $0) })
        XCTAssertEqual(result.due.map { calendar.component(.hour, from: $0) }, 9)
        XCTAssertTrue(result.timed)
    }

    func testPickingDayPreservesTypedTime() {
        var draft = InlineReminderDraft()
        let day = calendar.date(from: DateComponents(year: 2026, month: 12, day: 4))!
        draft.day = .custom(day)
        let result = draft.resolve("Call plumber at 3pm", calendar: calendar)
        XCTAssertEqual(result.due.map { calendar.startOfDay(for: $0) }, day)
        XCTAssertEqual(result.due.map { calendar.component(.hour, from: $0) }, 15)
        XCTAssertTrue(result.timed)
    }

    func testFailedTravelRefreshKeepsEligibleAlerts() {
        XCTAssertEqual(TravelAlerts.obsoleteIDs(pending: ["leave-existing", "leave-deleted", "other"], eligible: ["leave-existing"], enabled: true), ["leave-deleted"])
        XCTAssertEqual(TravelAlerts.obsoleteIDs(pending: ["leave-existing", "other"], eligible: ["leave-existing"], enabled: false), ["leave-existing"])
    }

    func testMacExposesRemindersAlongsideCalendarModes() {
        XCTAssertTrue(MacView.allCases.contains(.reminders))
        XCTAssertNil(MacView.reminders.calendarMode)
        for mode in [CalendarDisplay.day, .threeDay, .week, .month, .year] {
            XCTAssertEqual(MacView.allCases.filter { $0.calendarMode == mode }.count, 1)
        }
    }
}

final class UIRefreshTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    func testQuickAddNoDueDateOverridesTypedPresetAndExplicitDates() {
        let day = Date.now
        let result = QuickAddResolution.resolve("Call plumber tomorrow at 9am", presetDay: day,
            chosenDay: day, chosenTime: DateComponents(hour: 14), timed: true, noDueDate: true, calendar: calendar)
        XCTAssertNil(result.date)
        XCTAssertTrue(result.allDay)
        XCTAssertEqual(result.title, QuickAddParser.parse("Call plumber tomorrow at 9am", calendar: calendar).title)
        XCTAssertNotNil(QuickAddResolution.resolve("Call plumber tomorrow at 9am", noDueDate: false, calendar: calendar).date)
    }
    func testQuickAddNoDueDateRemovesRepeatThatWouldRestoreDueDate() {
        let text = "Water plants every day"
        XCTAssertNotNil(QuickAddParser.parse(text).repeats)
        let result = QuickAddResolution.resolve(text, noDueDate: true)
        XCTAssertNil(result.date)
        XCTAssertNil(result.repeats)
    }
    func testQuickAddChipTimeKeepsTypedDay() {
        let text = "Call plumber next Friday"
        let typed = QuickAddParser.parse(text, calendar: calendar)
        let result = QuickAddResolution.resolve(text, chosenTime: DateComponents(hour: 9, minute: 15), timed: true, calendar: calendar)
        XCTAssertNotNil(result.date)
        XCTAssertEqual(result.date.map { calendar.startOfDay(for: $0) }, typed.date.map { calendar.startOfDay(for: $0) })
        XCTAssertEqual(result.date.map { calendar.component(.hour, from: $0) }, 9)
        XCTAssertEqual(result.date.map { calendar.component(.minute, from: $0) }, 15)
        XCTAssertFalse(result.allDay)
    }
    func testQuickAddChipDateKeepsTypedTime() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        let result = QuickAddResolution.resolve("Dinner at 7pm", chosenDay: date, calendar: calendar)
        XCTAssertEqual(result.date.map { calendar.startOfDay(for: $0) }, date)
        XCTAssertEqual(result.date.map { calendar.component(.hour, from: $0) }, 19)
        XCTAssertFalse(result.allDay)
    }
    func testQuickAddAllDayOverrideRemovesTypedTime() {
        let result = QuickAddResolution.resolve("Conference tomorrow at 9am", timed: false, calendar: calendar)
        XCTAssertNotNil(result.date)
        XCTAssertEqual(result.date.map { calendar.component(.hour, from: $0) }, 0)
        XCTAssertTrue(result.allDay)
    }
    func testPresetDayDoesNotOverrideExplicitTypedDay() {
        let preset = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        let text = "Call next Friday at 3pm"
        XCTAssertEqual(QuickAddResolution.resolve(text, presetDay: preset, calendar: calendar).date,
                       QuickAddParser.parse(text, calendar: calendar).date)
        let timed = QuickAddResolution.resolve("Call at 3pm", presetDay: preset, calendar: calendar)
        XCTAssertEqual(timed.date.map { calendar.startOfDay(for: $0) }, preset)
    }
    func testSettingsSearchFindsHiddenControlsAndSupportsMultipleWords() {
        XCTAssertTrue(SettingsCategory.allCases.filter { $0.matches("weather") }.isEmpty)
        XCTAssertEqual(SettingsCategory.allCases.filter { $0.matches("accent color") }, [.appearance])
        XCTAssertEqual(SettingsCategory.allCases.filter { $0.matches("time leave") }, [.alerts])
        XCTAssertEqual(SettingsCategory.allCases.filter { $0.matches("undated") }, [.agenda])
        XCTAssertTrue(SettingsCategory.allCases.filter { $0.matches("nonexistent") }.isEmpty)
        XCTAssertEqual(SettingsCategory.allCases.filter { $0.matches("  ") }.count, 6)
    }
}


extension FixesAndFeaturesTests {
    @MainActor func testReminderNotificationUsesExplicitAlarmAndSkipsPastTimes() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(25, hour: 10))
        reminder.alarms = [EKAlarm(absoluteDate: date(25, hour: 9)), EKAlarm(absoluteDate: date(24, hour: 8))]
        XCTAssertEqual(ReminderNotifications.dates(for: reminder, now: date(24, hour: 12), option: .none, includeOwnAlarms: true, calendar: calendar), [date(25, hour: 9)])
        // Apple Reminders delivers a reminder's own alarms, so by default the app adds no second alert.
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: date(24, hour: 12), option: .none, includeOwnAlarms: false, calendar: calendar).isEmpty)
        reminder.isCompleted = true
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: date(24), calendar: calendar).isEmpty)
    }
    @MainActor func testReminderNotificationRespectsDisabledDefaultsAndUntimedTasks() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: date(25))
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: date(24), dateOnly: false, calendar: calendar).isEmpty)
        XCTAssertEqual(ReminderNotifications.dates(for: reminder, now: date(24), dateOnly: true, minute: 540, calendar: calendar), [date(25, hour: 9)])
        reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(25, hour: 10))
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: date(24), option: .none, calendar: calendar).isEmpty)
    }
    @MainActor func testReminderNotificationDoesNotConvertLocationAlarmToTimeAlert() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(25, hour: 10))
        let alarm = EKAlarm(); alarm.structuredLocation = EKStructuredLocation(title: "Home"); alarm.proximity = .enter
        reminder.alarms = [alarm]
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: date(24), calendar: calendar).isEmpty)
    }
}


extension FixesAndFeaturesTests {
    @MainActor func testNotificationTapSurvivesColdLaunchUntilHandled() {
        let defaults = makeDefaults()
        let initial = ReminderNotificationRoute(defaults: defaults)
        initial.open("first-reminder")
        let afterLaunch = ReminderNotificationRoute(defaults: defaults)
        XCTAssertEqual(afterLaunch.reminderID, "first-reminder")
        afterLaunch.open("newer-reminder")
        afterLaunch.handled("first-reminder")
        XCTAssertEqual(afterLaunch.reminderID, "newer-reminder")
        afterLaunch.handled("newer-reminder")
        XCTAssertNil(ReminderNotificationRoute(defaults: defaults).reminderID)
    }
}
