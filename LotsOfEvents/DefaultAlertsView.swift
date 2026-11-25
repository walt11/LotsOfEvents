import SwiftUI

/// Default alert times, laid out like Apple Calendar's and Reminders' settings.
struct DefaultAlertsView: View {
    static let deliveryNote = "Calendar event alerts are delivered by Apple Calendar. A reminder's own alerts are delivered by Apple Reminders. LotsOfEvents alerts you for reminders that have none, and can include the others from Settings → Alerts if you've turned off Apple Reminders notifications."
    // The same keys and defaults as AlertDefaults, in the shared App Group.
    @AppStorage("alertEvent", store: Preferences.defaults) private var eventAlert = EventAlertOption.minutes15.rawValue
    @AppStorage("alertAllDayEvent", store: Preferences.defaults) private var allDayAlert = AllDayAlertOption.dayOf.rawValue
    @AppStorage("alertReminder", store: Preferences.defaults) private var reminderAlert = ReminderAlertOption.atTime.rawValue
    @AppStorage("alertAllDayMinute", store: Preferences.defaults) private var allDayMinute = 540
    @AppStorage("alertDateOnly", store: Preferences.defaults) private var dateOnlyAlert = false
    @AppStorage("alertDateOnlyMinute", store: Preferences.defaults) private var dateOnlyMinute = 540
    var body: some View {
        Form {
            Section {
                Picker("Events", selection: $eventAlert) {
                    ForEach(EventAlertOption.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("All-Day Events", selection: $allDayAlert) {
                    ForEach(AllDayAlertOption.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if allDayAlert != AllDayAlertOption.none.rawValue {
                    DatePicker("All-Day Alert Time", selection: timeBinding($allDayMinute), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Calendar") } footer: {
                Text("Added to new events you create in LotsOfEvents. You can still change or remove an event’s alert when editing it.")
            }
            Section {
                Picker("With a time", selection: $reminderAlert) {
                    ForEach(ReminderAlertOption.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("With only a date", isOn: $dateOnlyAlert)
                if dateOnlyAlert {
                    DatePicker("Alert at", selection: timeBinding($dateOnlyMinute), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Reminders") } footer: {
                Text("Reminders with only a date get an alert on their due day at this time, like the Today Notification in Apple Reminders. Leave it off if Reminders already notifies you, to avoid two alerts.")
            }
            Section {
                Text(Self.deliveryNote)
                    .font(.footnote).foregroundStyle(GalleryPalette.muted)
            }.listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .navigationTitle("Default Alerts").navigationBarTitleDisplayMode(.inline)
    }
    /// Shows a stored minutes-after-midnight value as a time of day.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now)! },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 9) * 60 + (c.minute ?? 0) })
    }
}
