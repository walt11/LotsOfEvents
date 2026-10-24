import SwiftUI
import WidgetKit

/// Control Center / Lock Screen buttons that prompt for a phrase at the top of the screen without opening the app.
struct QuickAddEventControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickAddEventControl") {
            ControlWidgetButton(action: QuickAddIntent(kind: .event)) {
                Label("Add Event", systemImage: "calendar.badge.plus")
            }
        }
        .displayName("Add Event")
        .description("Type an event like “Lunch Friday 1pm” without opening LotsOfEvents.")
    }
}

struct QuickAddReminderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickAddReminderControl") {
            ControlWidgetButton(action: QuickAddIntent(kind: .reminder)) {
                Label("Add Reminder", systemImage: "checklist")
            }
        }
        .displayName("Add Reminder")
        .description("Type a reminder like “Call pharmacy tomorrow 10am” without opening LotsOfEvents.")
    }
}
