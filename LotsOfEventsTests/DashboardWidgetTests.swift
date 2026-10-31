import XCTest
import EventKit
import SwiftUI
import WidgetKit
@testable import LotsOfEvents

final class DashboardWidgetTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.firstWeekday = 2
        return c
    }
    private func date(_ day: Int, month: Int = 10, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func testNextUpExcludesEndedAllDayAndReminders() {
        let now = date(24, hour: 12)
        func event(_ id: String, start: Int, end: Int, allDay: Bool = false, reminder: Bool = false) -> AgendaItem {
            AgendaItem(id: id, title: id, date: date(24, hour: start), allDay: allDay, reminder: reminder, source: "Test", color: .blue, endDate: date(24, hour: end))
        }
        let items = [event("ended", start: 9, end: 12), event("next", start: 14, end: 15), event("ongoing", start: 11, end: 13), event("allDay", start: 0, end: 23, allDay: true), event("task", start: 14, end: 15, reminder: true)]
        XCTAssertEqual(WidgetDashboardData.nextEvents(items, now: now).map(\.id), ["ongoing", "next"])
    }
    func testFiveDaySelectionResetsWhenSavedDateExpires() {
        let now = date(24)
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(26), now: now, month: false, calendar: calendar), date(26))
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(23), now: now, month: false, calendar: calendar), now)
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(29), now: now, month: false, calendar: calendar), now)
    }
    func testMonthSelectionCanSelectPastDayButResetsAcrossMonths() {
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(1), now: date(24), month: true, calendar: calendar), date(1))
        XCTAssertEqual(WidgetDashboardData.selectedDay(saved: date(30, month: 9), now: date(24), month: true, calendar: calendar), date(24))
    }
    func testMonthGridHonorsFirstWeekdayAndSixWeekMonths() {
        let grid = WidgetDashboardData.monthDays(date(15, month: 3), calendar: calendar)
        XCTAssertEqual(grid.prefix(6).compactMap { $0 }.count, 0)
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
        XCTAssertEqual((grid.count + 6) / 7, 6)
        XCTAssertEqual(grid.compactMap { $0 }.last, date(31, month: 3))
    }
    func testFocusOrdersOverdueThenScheduledThenUndatedAndPriority() {
        func task(_ id: String, due: Date?, priority: Int = 0) -> WidgetTask {
            WidgetTask(id: id, title: id, due: due, timed: false, list: "Test", color: .blue, writable: true, priority: priority)
        }
        let tasks = [task("undated", due: nil), task("later", due: date(28)), task("due", due: date(24)), task("overdue", due: date(23)), task("priority", due: date(24), priority: 1)]
        XCTAssertEqual(WidgetDashboardData.sortedTasks(tasks).map(\.id), ["overdue", "priority", "due", "later", "undated"])
    }
}

final class WidgetCompanionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private func date(_ day: Int = 30, hour: Int = 0, minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func event(_ id: String, start: Date, end: Date, allDay: Bool = false, busy: Bool = true) -> AgendaItem {
        AgendaItem(id: id, title: id, date: start, allDay: allDay, reminder: false, source: "Test", color: .blue, endDate: end, blocksAvailability: busy)
    }
    private func task(_ id: String, due: Date?, timed: Bool = false, priority: Int = 0) -> WidgetTask {
        WidgetTask(id: id, title: id, due: due, timed: timed, list: "Test", color: .blue, writable: true, priority: priority)
    }
    func testOpenTimeMergesOverlapsAndClampsToNowAndWorkHours() {
        let items = [event("a", start: date(hour: 8), end: date(hour: 10)),
                     event("b", start: date(hour: 9), end: date(hour: 11)),
                     event("c", start: date(hour: 13), end: date(hour: 18))]
        let slots = WidgetCompanionData.openSlots(items: items, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(slots, [DateInterval(start: date(hour: 11), end: date(hour: 13))])
    }
    func testAllDayBusyBlocksButFreeDoesNot() {
        let busy = event("trip", start: date(), end: date(31), allDay: true)
        XCTAssertTrue(WidgetCompanionData.openSlots(items: [busy], now: date(hour: 9), calendar: calendar).isEmpty)
        var free = busy; free.blocksAvailability = false
        XCTAssertEqual(WidgetCompanionData.openSlots(items: [free], now: date(hour: 9), calendar: calendar).first?.duration, 8 * 3600)
    }
    func testMinimumGapAndInvalidWorkHours() {
        let items = [event("busy", start: date(hour: 9, minute: 20), end: date(hour: 17))]
        XCTAssertTrue(WidgetCompanionData.openSlots(items: items, now: date(hour: 9), calendar: calendar).isEmpty)
        XCTAssertEqual(WidgetCompanionData.openSlots(items: items, now: date(hour: 9), minimumMinutes: 15, calendar: calendar).first?.duration, 20 * 60)
        XCTAssertTrue(WidgetCompanionData.openSlots(items: [], now: date(hour: 9), startHour: 18, endHour: 9, calendar: calendar).isEmpty)
        XCTAssertTrue(WidgetCompanionData.openSlots(items: [], now: date(hour: 18), calendar: calendar).isEmpty)
    }
    func testOpenTimeUsesWallClockHoursAcrossFallDST() {
        let slots = WidgetCompanionData.openSlots(items: [], now: date(1, hour: 0, month: 11), startHour: 0, endHour: 3, calendar: calendar)
        XCTAssertEqual(slots.first?.end, date(1, hour: 3, month: 11))
        XCTAssertEqual(slots.first?.duration, 4 * 3600)
    }
    func testTomorrowBriefExcludesUndatedOverdueAndOtherDays() {
        let tasks = [task("old", due: date(29)), task("today", due: date()), task("tomorrow", due: date(31, hour: 8)), task("later", due: date(1, month: 11)), task("undated", due: nil)]
        XCTAssertEqual(WidgetCompanionData.tomorrowTasks(tasks, now: date(hour: 23), calendar: calendar).map(\.id), ["tomorrow"])
    }
    func testCatchUpIncludesTimedTodayButNotAllDayTodayAndSortsPriorityFirst() {
        let tasks = [task("old", due: date(28)), task("important", due: date(29), priority: 1),
                     task("earlier", due: date(hour: 9), timed: true), task("today", due: date()),
                     task("later", due: date(hour: 17), timed: true), task("undated", due: nil)]
        XCTAssertEqual(WidgetCompanionData.overdueTasks(tasks, now: date(hour: 12), calendar: calendar).map(\.id), ["important", "old", "earlier"])
    }
    func testPlanTimeLinkRoundTripsExactIntervalAndRejectsMalformedRanges() {
        let slot = DateInterval(start: date(hour: 11, minute: 15), end: date(hour: 12, minute: 30))
        XCTAssertEqual(WidgetCompanionData.eventInterval(from: WidgetCompanionData.eventURL(for: slot)), slot)
        for raw in ["lotsofevents://plan-time?start=nan&end=inf", "lotsofevents://plan-time?start=10&end=5", "lotsofevents://plan-time?start=0&end=1000000000", "lotsofevents://plan-time"] {
            XCTAssertNil(WidgetCompanionData.eventInterval(from: URL(string: raw)!))
        }
    }
    func testCompanionPagesPreserveEveryRowIncludingOversizedText() {
        XCTAssertEqual(WidgetCompanionData.pages(heights: [28, 17, 33, 28], height: 55), [0..<2, 2..<3, 3..<4])
        XCTAssertEqual(WidgetCompanionData.pages(heights: [80, 80], height: 20), [0..<1, 1..<2])
        XCTAssertEqual(WidgetCompanionData.pages(heights: [], height: 20), [0..<0])
    }
}

// Render the actual widget views at the smallest supported preview size. Attachments make
// compact and large-text layouts inspectable without changing live calendars or reminders.
@MainActor
final class WidgetRenderingTests: XCTestCase {
    func testCompanionWidgetRendering() throws {
        for large in [false, true] {
            for dark in [false, true] {
                let scheme: ColorScheme = dark ? .dark : .light
                var look = WidgetLook()
                if large { look.textSize = .extraLarge; look.density = .roomy }
                var agenda = WidgetPreviewData.agenda(threeDay: false)
                agenda.theme = .gallery; agenda.look = look
                var three = WidgetPreviewData.agenda(threeDay: true)
                three.theme = .gallery; three.look = look
                let content = VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        tile(AgendaWidgetView(entry: agenda), scheme: scheme)
                        tile(ThreeDayAgendaView(entry: three), scheme: scheme)
                        dashboard(.next, look: look, scheme: scheme)
                    }
                    HStack(spacing: 12) {
                        dashboard(.split, look: look, scheme: scheme)
                        dashboard(.five, look: look, scheme: scheme)
                        dashboard(.month, look: look, scheme: scheme)
                    }
                    HStack(spacing: 12) {
                        dashboard(.open, look: look, scheme: scheme)
                        dashboard(.tomorrow, look: look, scheme: scheme)
                        dashboard(.catchUp, look: look, scheme: scheme)
                    }
                    HStack(spacing: 12) {
                        dashboard(.focus, look: look, scheme: scheme)
                        Color.clear.frame(width: 170, height: 170)
                        Color.clear.frame(width: 170, height: 170)
                    }
                }.padding(12).background(dark ? Color.black : Color(white: 0.87))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertGreaterThan(image.size.width, 500)
                let name = "widgets-\(large ? "large-text" : "standard")-\(dark ? "dark" : "light")"
                let attachment = XCTAttachment(image: image)
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
                try image.pngData()?.write(to: path)
                print("WIDGET_RENDER: \(path.path)")
            }
        }
    }
    private func tile<V: View>(_ view: V, scheme: ColorScheme) -> some View {
        view.frame(width: 170, height: 170).background(AgendaTheme.gallery.background(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 24)).environment(\.colorScheme, scheme)
    }
    private func dashboard(_ kind: DashboardKind, look: WidgetLook, scheme: ColorScheme) -> some View {
        var entry = WidgetPreviewData.dashboard(kind)
        entry.look = look; entry.theme = .gallery
        return tile(DashboardView(entry: entry, kind: kind, previewFamily: .systemSmall), scheme: scheme)
    }

    func testOnlyBusyEventsTakeUpOpenTime() {
        // Holidays and other subscribed all-day events don't track availability, so they leave the day open.
        XCTAssertFalse(EKEvent.blocksTime(availability: .notSupported, allDay: true))
        XCTAssertTrue(EKEvent.blocksTime(availability: .busy, allDay: true))
        XCTAssertTrue(EKEvent.blocksTime(availability: .notSupported, allDay: false))
        XCTAssertFalse(EKEvent.blocksTime(availability: .free, allDay: false))
        XCTAssertFalse(EKEvent.blocksTime(availability: .busy, allDay: false, birthday: true))
        XCTAssertFalse(EKEvent.blocksTime(availability: .busy, allDay: false, canceled: true))
    }
}
