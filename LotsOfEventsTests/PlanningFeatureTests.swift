import XCTest
import EventKit
@testable import LotsOfEvents

final class PlanningFeatureTests: XCTestCase {
    func testReminderIdentityKeepsDistinctTasksWithMatchingTitles() {
        let store = EKEventStore()
        let first = EKReminder(eventStore: store)
        first.title = "Apply Insecticide"
        let second = EKReminder(eventStore: store)
        second.title = first.title
        let result = ReminderIdentity.unique([first, first, second])
        XCTAssertEqual(result.count, 2)
    }
    func testSharedReminderIdentityKeepsListsAndOccurrencesDistinct() {
        let due = DateComponents(year: 2026, month: 11, day: 24)
        let key = ReminderIdentity.ServerKey(listID: "shared", itemID: "task", due: due, start: nil, completed: false)
        let duplicate = ReminderIdentity.ServerKey(listID: "shared", itemID: "task", due: due, start: nil, completed: false)
        let next = ReminderIdentity.ServerKey(listID: "shared", itemID: "task", due: DateComponents(year: 2026, month: 12, day: 24), start: nil, completed: false)
        let other = ReminderIdentity.ServerKey(listID: "other", itemID: "task", due: due, start: nil, completed: false)
        XCTAssertEqual(Set([key, duplicate, next, other]).count, 3)
    }
    @MainActor func testEventCacheDoesNotRetainPartialResultsDuringRefresh() {
        let model = AgendaModel()
        let range = DateInterval(start: Date(timeIntervalSince1970: 1800000000), duration: 86400)
        let contact = EKEvent(eventStore: model.store)
        contact.title = "Contact anniversary"
        let event = EKEvent(eventStore: model.store)
        event.title = "Meeting"
        model.loading = true
        XCTAssertEqual(model.cachedEvents(in: range) { [contact] }.first?.title, "Contact anniversary")
        model.loading = false
        XCTAssertEqual(model.cachedEvents(in: range) { [event] }.first?.title, "Meeting")
        XCTAssertEqual(model.cachedEvents(in: range) { [] }.first?.title, "Meeting")
    }
    @MainActor func testExistingAlarmPreferenceDefaultsToEnabledAndRespectsOptOut() {
        let name = "AlarmMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ReminderNotifications.includesOwnAlarms(in: defaults))
        defaults.set(false, forKey: ReminderNotifications.includeOwnAlarmsKey)
        XCTAssertFalse(ReminderNotifications.includesOwnAlarms(in: defaults))
    }
    func testLegacyPreparationSurvivesMovingEvent() {
        let name = "BufferMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let event = EKEvent(eventStore: EKEventStore())
        event.startDate = Date(timeIntervalSince1970: 1800000000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        defaults.set(25, forKey: "planning.preparation.\(event.calendarItemIdentifier).\(event.startDate.timeIntervalSince1970)")
        XCTAssertEqual(PlanningPreferences.buffer(event, travel: false, in: defaults), 25)
        event.startDate = event.startDate.addingTimeInterval(86400)
        XCTAssertEqual(PlanningPreferences.buffer(event, travel: false, in: defaults), 25)
    }
    @MainActor func testExplicitSnoozeOverridesDisabledDefaultAndOwnAlarms() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let now = Date(timeIntervalSince1970: 1800000000)
        let due = now.addingTimeInterval(3600)
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: now))
        let key = ReminderNotifications.snoozeKey(reminder.calendarItemIdentifier)
        let old = Preferences.defaults.object(forKey: key)
        defer {
            if let old { Preferences.defaults.set(old, forKey: key) }
            else { Preferences.defaults.removeObject(forKey: key) }
        }
        Preferences.defaults.set(due.timeIntervalSince1970, forKey: key)
        XCTAssertEqual(ReminderNotifications.dates(for: reminder, now: now, option: .none, includeOwnAlarms: false), [due])
        reminder.isCompleted = true
        XCTAssertTrue(ReminderNotifications.dates(for: reminder, now: now).isEmpty)
    }
    func testMonthlyQuickAddKeepsTitleAndSpecificRecurrenceDay() {
        let parsed = QuickAddParser.parse("Pay rent every month on the first")
        XCTAssertEqual(parsed.title, "Pay rent")
        XCTAssertEqual(parsed.repeats?.monthDay, 1)
        XCTAssertEqual(parsed.repeats?.rule.daysOfTheMonth, [1])
        XCTAssertEqual(Calendar.current.component(.day, from: parsed.date!), 1)
        XCTAssertTrue(parsed.allDay)
        let other = QuickAddParser.parse("Pay bill monthly on the 15th at 10am")
        XCTAssertEqual(other.title, "Pay bill")
        XCTAssertEqual(other.repeats?.monthDay, 15)
        XCTAssertEqual(Calendar.current.component(.day, from: other.date!), 15)
        XCTAssertEqual(Calendar.current.component(.hour, from: other.date!), 10)
        XCTAssertFalse(other.allDay)
    }
    func testWidgetResetOffAndLongerTimeout() {
        let name = "PlanningTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 10000)
        defaults.set(now.timeIntervalSince1970, forKey: "test")
        defaults.set(0.0, forKey: "widgetReset.test")
        XCTAssertNil(WidgetDayNavigation.resetDate(key: "test", in: defaults))
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(1000), key: "test", in: defaults))
        defaults.set(300.0, forKey: "widgetReset.test")
        XCTAssertTrue(WidgetDayNavigation.isActive(at: now.addingTimeInterval(299), key: "test", in: defaults))
        XCTAssertFalse(WidgetDayNavigation.isActive(at: now.addingTimeInterval(300), key: "test", in: defaults))
    }
    func testUnrelatedDragCannotScheduleTask() {
        XCTAssertNil(ReminderDrag.identifier("https://example.com"))
        XCTAssertNil(ReminderDrag.identifier(ReminderDrag.prefix))
        XCTAssertEqual(ReminderDrag.identifier(ReminderDrag.payload("task-123")), "task-123")
    }
    func testPreparationDetectsTightGaps() {
        let end = Date(timeIntervalSince1970: 10000)
        XCTAssertTrue(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(600), minutes: 15))
        XCTAssertFalse(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(900), minutes: 15))
        XCTAssertTrue(PlanningPreferences.insufficientGap(previousEnd: end, nextStart: end.addingTimeInterval(-60), minutes: 0))
    }
    @MainActor func testWidgetCompletionCanBeUndone() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw XCTSkip("Reminder permission required") }
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.title = "LotsOfEvents test undo \(UUID())"
        let previous = Preferences.defaults.data(forKey: WidgetUndoRecord.key)
        defer {
            try? store.remove(reminder, commit: true)
            if let previous { Preferences.defaults.set(previous, forKey: WidgetUndoRecord.key) }
            else { Preferences.defaults.removeObject(forKey: WidgetUndoRecord.key) }
        }
        try store.save(reminder, commit: true)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        let record = WidgetUndoRecord(token: UUID().uuidString, identifier: reminder.calendarItemIdentifier, title: reminder.title!, completedAt: reminder.completionDate!)
        record.save()
        try WidgetUndoRecord.undo(token: "stale-token")
        _ = reminder.refresh()
        XCTAssertTrue(reminder.isCompleted)
        try WidgetUndoRecord.undo(token: record.token)
        _ = reminder.refresh()
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertNil(WidgetUndoRecord.current)
    }
    @MainActor func testTaskDropSetsDueDateAndSupportsUndo() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw XCTSkip("Reminder permission required") }
        let model = AgendaModel()
        let reminder = EKReminder(eventStore: model.store)
        reminder.calendar = model.store.defaultCalendarForNewReminders()
        reminder.title = "LotsOfEvents test drag \(UUID())"
        try model.store.save(reminder, commit: true)
        defer { try? model.store.remove(reminder, commit: true) }
        let target = Calendar.current.date(bySettingHour: 14, minute: 15, second: 0, of: .now)!
        XCTAssertTrue(model.dropTasks([ReminderDrag.payload(reminder.calendarItemIdentifier)], on: target, timed: true))
        _ = reminder.refresh()
        XCTAssertEqual(ReminderDates.due(reminder), target)
        model.undo?.perform()
        _ = reminder.refresh()
        XCTAssertNil(reminder.dueDateComponents)
    }

}


final class ReviewFixTests: XCTestCase {
    private var calendar: Calendar { .current }
    func testWordsThatStartLikeDaysDoNotNameADay() {
        for text in ["Wedding shower", "Friends dinner", "Monica visit", "Sunny picnic", "Mayor meeting", "Decide on car", "Marketing sync 3pm", "Junk removal", "Novel club", "Call May 3pm", "Plan next steps"] {
            XCTAssertFalse(QuickAddParser.namesDay(text), text)
        }
        for text in ["Lunch Friday 1pm", "call tomorrow", "Dentist Oct 30", "Dentist 30 Oct", "Trip next week", "Gym mon", "Pay in 3 days", "Call in 2 hours", "6/12 party"] {
            XCTAssertTrue(QuickAddParser.namesDay(text), text)
        }
    }
    func testPresetDayIsKeptForAWordThatLooksLikeADay() {
        let preset = calendar.date(from: DateComponents(year: 2030, month: 12, day: 15))!
        let result = QuickAddResolution.resolve("Marketing sync 3pm", presetDay: preset)
        XCTAssertTrue(calendar.isDate(result.date!, inSameDayAs: preset))
        XCTAssertEqual(calendar.component(.hour, from: result.date!), 15)
    }
    func testDurations() {
        let lunch = QuickAddParser.parse("Lunch tomorrow for 90 minutes")
        XCTAssertEqual(lunch.title, "Lunch")
        XCTAssertEqual(lunch.duration, 5400)
        XCTAssertFalse(lunch.allDay)
        XCTAssertEqual(calendar.component(.hour, from: lunch.date!), 12)
        XCTAssertEqual(QuickAddParser.parse("Standup today 9am for half an hour").duration, 1800)
        XCTAssertEqual(QuickAddParser.parse("Standup today 9am for an hour").duration, 3600)
        let trip = QuickAddParser.parse("Camping Friday for 3 days")
        XCTAssertEqual(trip.title, "Camping")
        XCTAssertTrue(trip.allDay)
        XCTAssertEqual(trip.spanDays, 3)
    }
    func testTimeRanges() {
        let meeting = QuickAddParser.parse("Planning tomorrow 2-4pm")
        XCTAssertEqual(meeting.title, "Planning")
        XCTAssertEqual(meeting.duration, 7200)
        XCTAssertEqual(calendar.component(.hour, from: meeting.date!), 14)
        let across = QuickAddParser.parse("Workshop tomorrow 11-1pm")
        XCTAssertEqual(calendar.component(.hour, from: across.date!), 11)
        XCTAssertEqual(across.duration, 7200)
        let exact = QuickAddParser.parse("Review tomorrow 9:30am to 10:15am")
        XCTAssertEqual(exact.title, "Review")
        XCTAssertEqual(exact.duration, 2700)
    }
    func testRelativeDates() {
        let now = Date.now
        let soon = QuickAddParser.parse("Meeting in 2 hours", now: now)
        XCTAssertEqual(soon.title, "Meeting")
        XCTAssertEqual(soon.date, now.addingTimeInterval(7200))
        XCTAssertFalse(soon.allDay)
        let later = QuickAddParser.parse("Renew passport in 3 days", now: now)
        XCTAssertEqual(later.title, "Renew passport")
        XCTAssertTrue(later.allDay)
        XCTAssertEqual(later.date, calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now)))
    }
    func testDateRangesCoverEveryDay() {
        let conference = QuickAddParser.parse("Conference Dec 3-5")
        XCTAssertEqual(conference.title, "Conference")
        XCTAssertEqual(conference.spanDays, 3)
        XCTAssertEqual(calendar.component(.day, from: conference.date!), 3)
        XCTAssertEqual(QuickAddParser.parse("Vacation Dec 28 to Jan 2").spanDays, 6)
        XCTAssertEqual(QuickAddParser.parse("Retreat Friday to Sunday").spanDays, 3)
    }
    func testRichRepeats() {
        let gym = QuickAddParser.parse("Gym every Monday and Wednesday 6am")
        XCTAssertEqual(gym.title, "Gym")
        XCTAssertEqual(gym.repeats, QuickAddRepeat(frequency: .weekly, weekdays: [2, 4]))
        XCTAssertTrue([2, 4].contains(calendar.component(.weekday, from: gym.date!)))
        XCTAssertEqual(calendar.component(.hour, from: gym.date!), 6)
        let trash = QuickAddParser.parse("Trash every other Tuesday")
        XCTAssertEqual(trash.title, "Trash")
        XCTAssertEqual(trash.repeats, QuickAddRepeat(frequency: .weekly, weekdays: [3], interval: 2))
        XCTAssertEqual(trash.repeats?.rule.interval, 2)
        let standup = QuickAddParser.parse("Standup weekdays 9am")
        XCTAssertEqual(standup.title, "Standup")
        XCTAssertEqual(standup.repeats?.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(QuickAddParser.parse("Water plants every 3 days").repeats, QuickAddRepeat(frequency: .daily, interval: 3))
        XCTAssertEqual(QuickAddParser.parse("Yoga Tuesdays and Thursdays 7pm").repeats?.weekdays, [3, 5])
        XCTAssertEqual(QuickAddParser.parse("Pay card biweekly").repeats, QuickAddRepeat(frequency: .weekly, interval: 2))
    }
    func testASingleMealWordIsATitle() {
        XCTAssertEqual(QuickAddParser.parse("Lunch").title, "Lunch")
        XCTAssertNil(QuickAddParser.parse("Lunch").date)
        XCTAssertEqual(QuickAddParser.parse("tomorrow").title, "")
    }
    func testOverdueRowsShowTheirDate() {
        let earlier = calendar.date(byAdding: .day, value: -3, to: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!)!
        let timed = AgendaItem(id: "a", title: "Task", date: earlier, allDay: false, reminder: true, source: "List", color: .blue)
        XCTAssertTrue(timed.timeLabel.contains(earlier.formatted(.dateTime.month(.abbreviated).day())))
        let today = AgendaItem(id: "b", title: "Task", date: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!, allDay: false, reminder: true, source: "List", color: .blue)
        XCTAssertEqual(today.timeLabel, today.date.formatted(date: .omitted, time: .shortened))
    }
    func testContinuationRowsKeepTheirDetails() throws {
        let start = calendar.startOfDay(for: .now)
        let url = URL(string: "https://zoom.us/j/1")!
        let item = AgendaItem(id: "e", title: "Offsite", date: start.addingTimeInterval(3600), allDay: false, reminder: false, source: "Work", color: .blue,
                              eventStartDate: start.addingTimeInterval(3600), endDate: start.addingTimeInterval(30 * 3600), joinURL: url, needsReply: true, blocksAvailability: false)
        let rows = WidgetAgendaLayout.byDay([item], start: start, days: 2)
        let second = try XCTUnwrap(rows.last)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(second.joinURL, url)
        XCTAssertTrue(second.needsReply)
        XCTAssertFalse(second.blocksAvailability)
    }
    func testFreeAndDeclinedEventsDoNotConflict() {
        let start = Date.now
        func item(_ id: String, blocks: Bool) -> AgendaItem {
            AgendaItem(id: id, title: id, date: start, allDay: false, reminder: false, source: "", color: .blue, eventStartDate: start, endDate: start + 3600, blocksAvailability: blocks)
        }
        XCTAssertEqual(Conflicts.ids(items: [item("a", blocks: true), item("free", blocks: false)]), [])
        XCTAssertEqual(Conflicts.ids(items: [item("a", blocks: true), item("b", blocks: true)]), ["a", "b"])
        XCTAssertFalse(EKEvent.blocksTime(availability: .busy, allDay: false, declined: true))
    }
    func testBufferCountsTowardConflicts() {
        let start = Date.now
        var later = AgendaItem(id: "b", title: "b", date: start + 3600, allDay: false, reminder: false, source: "", color: .blue, eventStartDate: start + 3600, endDate: start + 7200)
        let first = AgendaItem(id: "a", title: "a", date: start, allDay: false, reminder: false, source: "", color: .blue, eventStartDate: start, endDate: start + 3500)
        XCTAssertEqual(Conflicts.ids(items: [first, later]), [])
        later.bufferMinutes = 30
        XCTAssertEqual(Conflicts.ids(items: [first, later]), ["a", "b"])
    }
    func testFocusEndingRestoresTheEarlierSelection() {
        let defaults = UserDefaults(suiteName: "focus-\(UUID().uuidString)")!
        defaults.set(["hiddenCalendar"], forKey: "hiddenCalendars")
        defaults.set(["hiddenList"], forKey: "hiddenReminderLists")
        CalendarSet.focusBegan(CalendarSet(name: "Work", hiddenCalendars: ["other"], hiddenLists: []), in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenCalendars"), ["other"])
        CalendarSet.focusEnded(in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenCalendars"), ["hiddenCalendar"])
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenReminderLists"), ["hiddenList"])
        // A Focus ending with nothing saved leaves the selection alone.
        CalendarSet.focusEnded(in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenCalendars"), ["hiddenCalendar"])
    }
    func testChineseCalendarYearsCountAcrossCycles() {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = .current
        var parts = DateComponents(); parts.calendar = chinese
        let reference = chinese.dateComponents([.era, .year], from: Calendar.current.date(from: DateComponents(year: 1990, month: 6, day: 1))!)
        parts.era = reference.era; parts.year = reference.year; parts.month = 3; parts.day = 10
        let record = ContactDateRecord(id: "x", contactID: "x", name: "Sam", label: "Birthday", components: parts, birthday: true)
        let later = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        XCTAssertTrue(record.title(on: later).hasSuffix("36 years"), record.title(on: later))
        // Without the cycle there's no way to know the count, so none is shown.
        var noEra = parts; noEra.era = nil
        let unknown = ContactDateRecord(id: "y", contactID: "y", name: "Sam", label: "Birthday", components: noEra, birthday: true)
        XCTAssertEqual(unknown.title(on: later), "Sam · Birthday")
    }
    func testMeetingLinksStillFound() {
        XCTAssertEqual(MeetingLink.url(url: nil, location: nil, notes: "Join at https://us02web.zoom.us/j/123")?.host, "us02web.zoom.us")
        XCTAssertNil(MeetingLink.url(url: nil, location: "Cafe", notes: "See https://example.com"))
    }
}
