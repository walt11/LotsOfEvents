# Review of Claude's changes — October 25, 2026

Reviewed the two newer commits (`efbdcd4`, `0b4edbc`), all current tracked diffs, and the new `Shared/WidgetStyle.swift`, against the previous work in this chat. No resets, reverts, or changes to Collager were made.

## Changes retained

- Calendar-first navigation, centered Quick Add button with full editors in its context menu, tab reselection, iPad sidebar, and reminder haptics.
- Day/week time grids, overlap columns, month event indicators, and original calendar colors.
- Continuous agenda, collapsed empty date ranges, direct reminder completion/snooze, location/duration details, and fewer redundant queries.
- Quick Add date/time shortcuts, destination picker, meal-word parsing, dictation callback isolation, and system controls/Shortcuts.
- Persistent multiple-list selection in Reminders, grouped tasks, compact controls, and short-lived usage hints.
- Blue default accent and app icon; shared accent migration for widgets.
- Custom widget gradients, borders and independent accent, contrast selection, day-tab alignment, and existing per-widget overrides.
- Deleted-calendar color/title/write-access fallbacks and expanded tests.

## Review findings to revisit

1. **Deleted-list safety is incomplete.** `RemindersHome.swift` still dereferences `reminder.calendar.calendarIdentifier` in its filter, read-only picker, and editor initialization; `ReminderSnapshot` in `MainView.swift` does the same. The newly added nil-safe helpers protect titles/colors, but a stale item whose calendar becomes nil can still crash on these paths. Static finding, not reproduced on the physical phone.
2. **Quick Add differs from the earlier half-height preference.** Its current `.task` focuses the field automatically and its detents include both medium and large. This latest behavior was preserved rather than silently undoing Claude's changes.
3. **Custom gradient contrast is only approximate.** `CustomWidgetStyle.text` chooses one text color from average endpoint luminance. A black-to-white gradient can still make that color unreadable at one end; average luminance does not guarantee contrast everywhere. No widget style was changed in this pass.

## Calendar changes in this pass

- Month grid shows only necessary complete weeks (4–6), retaining every day and respecting the user's first weekday.
- Date cells retain 44-point minimum touch targets and grow for accessibility text sizes.
- Compact event markers replace the always-reserved 20-point indicator stack.
- Search is opened explicitly from the toolbar and can be dismissed without losing the selected date.
- Event rows use Agenda's subheadline title, small metadata, compact insets, and section spacing.
- Day/week timelines, search scope, event editing, source selections, and navigation behavior remain intact.

## Validation

- Baseline: 44 tests passed with zero failures.
- Updated calendar: 45 tests passed with zero failures, including coverage for all months and multiple week starts.
- Simulator screenshot checked; signed device build succeeded and installed on John’s PDA.
- Overall redesign concepts are previews only, based on Collager's paper background, serif headings, monospaced labels, and rust accent.
