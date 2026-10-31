import SwiftUI
import WidgetKit

// Kept on its own so the app can compile the widget views for its in-app previews without a second @main.
@main
struct LotsOfEventsWidgets: WidgetBundle {
    var body: some Widget {
        UpcomingAgendaWidget()
        ThreeDayAgendaWidget()
        NextUpWidget()
        EventsTasksWidget()
        FiveDayStripWidget()
        MonthAgendaWidget()
        FocusListWidget()
        OpenTimeWidget()
        TomorrowBriefWidget()
        CatchUpWidget()
        TodayRemindersWidget()
        QuickAddEventControl()
        QuickAddReminderControl()
        #if !targetEnvironment(macCatalyst)
        NextEventLiveActivity()
        #endif
    }
}
