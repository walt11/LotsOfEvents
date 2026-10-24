# Lots of Events

Native SwiftUI iPhone/iPad agenda and WidgetKit extension. Requires iOS 18+ and Xcode 16+ (built with Xcode 27).

## Run

1. Open `LotsOfEvents.xcodeproj`, select the LotsOfEvents scheme and an iPhone simulator or device.
2. For a physical device, select your development team for both targets. Use unique bundle identifiers and register an App Group. Set the `APP_GROUP` build setting to that group for both targets; it drives entitlements and shared preferences.
3. Run the app, connect calendars, then open Sources to connect Reminders and select lists.
4. Add the Upcoming Agenda widget through the Home Screen widget gallery.

`project.yml` is the source of project configuration. Regenerate with `xcodegen generate` after changing it. No third-party runtime dependencies or server.

## Behavior

- Shows today (including earlier events) plus four more days by default; configurable from 2–14 days total.
- Includes events overlapping the range, and incomplete reminders with due dates inside it. Undated and earlier overdue reminders are excluded.
- Calendars default to selected; reminder lists are opt-in. Empty selection means no items of that type.
- Widgets offer seven selectable darker matte themes (Graphite, Slate, Sage, Sand, Clay, Lavender, Black). Black stays black; the others have light/dark variants, in Sources → Widget theme. The selection is shared with all widgets. Widgets group items under date headings on a flat themed background, with colored calendar bars and single-line items. Item notes and date subtitles are hidden in the widget. All-day items have no time label; timed events show their start–end time beneath the title, and timed reminders show their due time. Pages adapt to the space needed by headings and notes. Arrow buttons change pages without opening the app. The + deep link opens Apple’s native event editor; the widget background opens the full agenda.
- The native event editor supports calendars, all-day events, repeat rules, alerts, and locations.
- Widget queries EventKit on refresh and reads selections through the App Group. It requests a refresh every 15 minutes or at midnight, with actual timing controlled by iOS. The app also requests reloads after source changes, event changes, and foregrounding.
- Calendar and reminder data stays on device. The app does not upload it.

## Validation

Tests cover chronological merging and calendar-day date windows across daylight saving time. Run the LotsOfEvents scheme’s tests in Xcode.

Device acceptance checks: grant/deny each permission independently; select and deselect all sources; create and cancel an event; verify all-day/multi-day events and dated reminders; add all widget sizes, exercise page arrows and +, and check refresh after editing in Apple Calendar/Reminders. Verify small-widget tap routing and App Group provisioning on your signed physical device before distribution.

## Calendar and Reminders app

The app has three tabs:

- **Calendar:** month grid with event indicators and selected-day agenda; a seven-day week agenda; a day schedule with hourly add shortcuts; and a 30-day agenda. Navigate backward/forward, jump to a date, or return to Today. Search titles, locations, and notes within one year before/after the selected date. Calendar source switches apply to these views and the widget.
- **Upcoming:** the existing combined calendar/reminder agenda, using the widget date range and selected reminder lists. Tap an item to view/edit it.
- **Reminders:** Today (including overdue), Scheduled, All incomplete, and Completed smart views; browse any list, search titles/notes, and sort by due date or priority. This tab shows all accessible lists, independently of widget selections. Complete/reopen with the circle or swipe action.

Tap an event for Apple's native detail screen and Edit for supported changes/deletion, including recurring-event handling. The + button creates an event on the browsed date. The native editor handles calendar, repeat, alert, location, and notes fields.

Reminder editing includes title, notes, website URL, list moves, date-only/timed due dates, priority, completion, daily/weekly/monthly/yearly repeats, and time-based alerts. Existing complex repeats and alarms are preserved with Keep existing; changing due date shifts absolute alerts by the same interval. Removing the due date also removes repeats/alerts. Deletion requires confirmation and affects synced Apple Reminders data. Read-only lists cannot be changed.

This core release does not implement reminder subtasks, tags, attachments, shared-list collaboration, list/calendar creation or deletion, invitation management, or drag-and-drop scheduling. These require further work; some Apple Reminders features are not exposed by EventKit.

Validation: twenty-one simulator tests cover date windows, DST, month grids, midnight end boundaries, multi-day/zero-duration events, date-only/timed reminder components, stable theme identifiers, preservation of repeat rules, alarm offsets, and location alerts, plus widget pagination, time subtitles, and selected-day overlap filtering. Signed device build/install is verified separately. Live account synchronization and every edit flow still need device acceptance testing with your accounts.


## Three-Day Agenda widget

A second gallery option, **Three-Day Agenda**, displays today and the next two dates as tappable tabs. The selected day shows its events and selected reminders, including multi-day events that overlap it. Timed items show times beneath the title; all-day items have no subtitle. Busy days have independent page controls. It uses the same theme and source selections as Upcoming Agenda, but always loads three days regardless of the Upcoming date-range setting. Date/page selection is shared between instances of this widget. When a saved day leaves the three-day range, selection returns to today.

The original Upcoming Agenda widget keeps its existing gallery identity and layout. Add the new option through Home Screen → Edit → Add Widget → Lots of Events → Three-Day Agenda.


## Additional small widgets

All five options use the existing theme and selected sources. The original Upcoming Agenda and Three-Day Agenda remain available. Free Time is not included.

- **Next Up:** ongoing/next timed calendar event within 14 days, plus the following event. All-day entries and reminders are excluded. Local timeline entries switch at event starts/ends; iOS controls refresh scheduling.
- **Events + Tasks:** today's calendar events and selected incomplete reminders that are due today, overdue, or undated. Tap a reminder circle to complete it. Page controls expose overflow in both sections.
- **Five-Day Strip:** today plus four days, with interactive date selection and pagination for the selected day.
- **Month + Agenda:** the current month's date grid, event/reminder dots, and selected-day agenda. Date selection and page controls are interactive. Uses the device's first weekday.
- **Focus List:** all incomplete reminders from selected lists, including overdue, future, and undated items. Orders by due date, then priority. Complete tasks directly, add a reminder with +, or tap the background to open Reminders in the app.

These five layouts support the small widget size. Selections and page positions are independent across layouts but shared among instances of the same layout. Reminder completion writes to Apple Reminders, honors read-only lists, and refreshes all widgets. The UI never completes sample gallery reminders. Live reminder completion and account synchronization should be checked on-device.
