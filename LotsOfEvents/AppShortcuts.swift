import AppIntents
import EventKit
import WidgetKit

enum ShortcutError: LocalizedError {
    case noAccess, noList
    var errorDescription: String? {
        switch self {
        case .noAccess: return "Open LotsOfEvents and allow Reminders access."
        case .noList: return "Choose a default list in the Reminders app."
        }
    }
}

struct NextEventIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Next"
    static let description = IntentDescription("Tells you your next event from the calendars selected in LotsOfEvents.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .result(dialog: "Open LotsOfEvents to connect your calendars.") }
        let items = await AgendaQuery.load(store: EKEventStore(), days: 14)
        guard let next = WidgetDashboardData.nextEvents(items, now: .now).first else { return .result(dialog: "Nothing is on your calendar for the next two weeks.") }
        let start = next.eventStartDate ?? next.date
        let when = start <= .now ? "is happening now"
            : Calendar.current.isDateInToday(start) ? "at \(start.formatted(date: .omitted, time: .shortened))"
            : "on \(start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))"
        return .result(dialog: "\(next.title) \(when).")
    }
}

struct AddReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Reminder"
    static let description = IntentDescription("Adds a reminder to your default Reminders list.")
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Due") var due: Date?
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$title) due \(\.$due)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw ShortcutError.noAccess }
        guard let list = store.defaultCalendarForNewReminders() else { throw ShortcutError.noList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = ReminderDates.components(due, timed: true)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Added “\(title)” to \(list.title).")
    }
}

struct LotsOfEventsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextEventIntent(), phrases: ["What's next in \(.applicationName)", "What's my next event in \(.applicationName)"], shortTitle: "What's Next", systemImageName: "calendar")
        AppShortcut(intent: AddReminderIntent(), phrases: ["Add a reminder in \(.applicationName)"], shortTitle: "Add Reminder", systemImageName: "checklist")
    }
}
