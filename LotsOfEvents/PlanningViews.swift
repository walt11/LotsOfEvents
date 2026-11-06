import SwiftUI
import EventKit
import Contacts
import UserNotifications
import WidgetKit

extension AgendaModel {
    @discardableResult func dropTasks(_ payloads: [String], on date: Date, timed: Bool = false) -> Bool {
        let ids = Set(payloads.compactMap(ReminderDrag.identifier))
        var handled = false
        for id in ids {
            if let reminder = reminder(withID: id), reminder.isWritable, !reminder.isCompleted {
                snooze(reminder, until: date, timed: timed)
                handled = true
            }
        }
        return handled
    }
}

struct WeeklyPlanner: View {
    @ObservedObject var model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    @State private var week = Date.now
    @State private var scheduling: EKReminder?
    @State private var chosenDate = Date.now
    @State private var timed = false
    private var days: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: week)!.start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private var tasks: [EKReminder] {
        model.reminders.filter { !$0.isCompleted && Preferences.selected($0.calendar.calendarIdentifier, reminders: true) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Previous week", systemImage: "chevron.left") { shift(-7) }.labelStyle(.iconOnly)
                        Spacer()
                        Button("This Week") { week = .now }
                        Spacer()
                        Button("Next week", systemImage: "chevron.right") { shift(7) }.labelStyle(.iconOnly)
                    }
                    Text("Drag a task onto a day, or tap its calendar button to choose a day and time.").font(.footnote).foregroundStyle(.secondary)
                }
                let backlog = tasks.filter { ReminderDates.due($0) == nil || ReminderDates.isOverdue($0) }
                if !backlog.isEmpty {
                    Section("Unscheduled & Overdue") {
                        ForEach(backlog, id: \.calendarItemIdentifier) { task($0) }
                    }
                }
                ForEach(days, id: \.self) { day in
                    Section {
                        let events = model.events(in: CalendarDates.dayRange(day))
                        let scheduled = tasks.filter { ReminderDates.due($0).map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
                        if events.isEmpty && scheduled.isEmpty { Text("Open day · drop a task here").foregroundStyle(.secondary) }
                        ForEach(events, id: \.occurrenceKey) { event in
                            Button { model.inspect(event) } label: {
                                HStack {
                                    Circle().fill(event.calendarColor).frame(width: 6, height: 6)
                                    Text(event.title ?? "Event").foregroundStyle(.primary)
                                    Spacer()
                                    Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                        ForEach(scheduled, id: \.calendarItemIdentifier) { task($0) }
                    } header: { Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) }
                    .dropDestination(for: String.self) { payloads, _ in model.dropTasks(payloads, on: day) }
                }
            }
            .navigationTitle("Weekly Planner").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(get: { scheduling != nil }, set: { if !$0 { scheduling = nil } })) {
                if let reminder = scheduling { NavigationStack {
                    Form {
                        Text(reminder.title ?? "Task").font(.headline)
                        DatePicker("Day", selection: $chosenDate, displayedComponents: .date)
                        Toggle("Set a time", isOn: $timed)
                        if timed { DatePicker("Time", selection: $chosenDate, displayedComponents: .hourAndMinute) }
                    }
                    .navigationTitle("Schedule Task")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scheduling = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("Schedule") { model.snooze(reminder, until: chosenDate, timed: timed); scheduling = nil } }
                    }
                }.presentationDetents([.medium]) }
            }
        }.frame(idealWidth: 650, idealHeight: 700)
    }
    private func shift(_ days: Int) { week = Calendar.current.date(byAdding: .day, value: days, to: week)! }
    private func task(_ reminder: EKReminder) -> some View {
        HStack {
            ReminderLine(model: model, reminder: reminder, showNotes: false)
            Button("Schedule task", systemImage: "calendar.badge.clock") {
                chosenDate = ReminderDates.due(reminder) ?? week
                timed = reminder.dueDateComponents?.hour != nil
                scheduling = reminder
            }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!reminder.isWritable)
        }
    }
}

struct EventPlanningView: View {
    let event: EKEvent
    let model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    @State private var preparation = 0
    @State private var travel = 0
    private let options = [0, 5, 10, 15, 30, 45, 60, 90, 120]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Preparation", selection: $preparation) { ForEach(options, id: \.self) { Text($0 == 0 ? "None" : "\($0) minutes").tag($0) } }
                    Picker("Travel before event", selection: $travel) { ForEach(options, id: \.self) { Text($0 == 0 ? "None" : "\($0) minutes").tag($0) } }
                    if preparation + travel > 0 {
                        LabeledContent("Start getting ready", value: event.startDate.addingTimeInterval(-Double((preparation + travel) * 60)).formatted(date: .abbreviated, time: .shortened))
                    }
                } header: { Text(event.title ?? "Event") } footer: { Text("Reserved planning time in LotsOfEvents. Your event’s start time and Apple Calendar are unchanged. Use Time to Leave in Alerts for driving notifications.") }
                let preceding = model.events(in: DateInterval(start: event.startDate.addingTimeInterval(-86400), end: event.startDate)).filter { !$0.isAllDay && $0.occurrenceKey != event.occurrenceKey && $0.blocksTime }.max { $0.endDate < $1.endDate }
                if let preceding, PlanningPreferences.insufficientGap(previousEnd: preceding.endDate, nextStart: event.startDate, minutes: preparation + travel) {
                    Label("Not enough time after “\(preceding.title ?? "previous event")” for this preparation and travel.", systemImage: "exclamationmark.triangle").foregroundStyle(GalleryPalette.warning)
                }
            }
            .navigationTitle("Preparation & Travel").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                preparation = Preferences.defaults.integer(forKey: PlanningPreferences.bufferKey(event, travel: false))
                travel = Preferences.defaults.integer(forKey: PlanningPreferences.bufferKey(event, travel: true))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    Preferences.defaults.set(preparation, forKey: PlanningPreferences.bufferKey(event, travel: false))
                    Preferences.defaults.set(travel, forKey: PlanningPreferences.bufferKey(event, travel: true))
                    model.scheduleRefresh(); dismiss()
                } }
            }
        }.presentationDetents([.medium, .large])
    }
}

struct ConnectionStatusView: View {
    @ObservedObject var model: AgendaModel
    var body: some View {
        List {
            Section("Access") {
                LabeledContent("Calendars", value: model.calendarAccess ? "Connected" : "Access needed")
                LabeledContent("Reminders", value: model.reminderAccess ? "Connected" : "Access needed")
                LabeledContent("Contacts", value: ContactDateSync.allowed ? (CNContactStore.authorizationStatus(for: .contacts) == .limited ? "Limited access" : "Connected") : "Access not granted")
                if !model.calendarAccess { Button("Connect Calendars") { Task { await model.request(.event) } } }
                if !model.reminderAccess { Button("Connect Reminders") { Task { await model.request(.reminder) } } }
                Button("Open System Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Section("Refresh") {
                LabeledContent("Last refreshed", value: model.lastRefresh == .distantPast ? "Not yet" : model.lastRefresh.formatted(date: .abbreviated, time: .standard))
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Button(model.loading ? "Refreshing…" : "Refresh Now") { model.scheduleRefresh(); WidgetReloader.schedule() }.disabled(model.loading)
                Text("This checks data available on this device. Account synchronization is managed by Apple Calendar and Reminders.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Included Calendars") {
                ForEach(model.calendars.filter { Preferences.selected($0.calendarIdentifier, reminders: false) }, id: \.calendarIdentifier) { Text($0.title) }
                if ContactDates.enabled { Text("Birthdays & Contact Dates · \(ContactDates.records.count) fields") }
            }
            Section("Included Reminder Lists") {
                ForEach(model.lists.filter { Preferences.selected($0.calendarIdentifier, reminders: true) }, id: \.calendarIdentifier) { Text($0.title) }
            }
        }.navigationTitle("Connection Status")
    }
}

struct WidgetResetSettings: View {
    private let widgets = [("Upcoming Agenda", "agendaPagedOn"), ("Three-Day Agenda", WidgetDayNavigation.interactionKey), ("Events + Tasks", "EventsTasksDays.interactedAt"), ("Five-Day Strip", "FiveDayStrip.interactedAt"), ("Month + Agenda", "MonthAgenda.interactedAt"), ("Focus List", "FocusList.interactedAt"), ("Open Time", "OpenTime.interactedAt"), ("Tomorrow Brief", "TomorrowBrief.interactedAt"), ("Catch Up", "CatchUp.interactedAt")]
    @State private var revision = 0
    var body: some View {
        Form {
            Section {
                ForEach(widgets, id: \.1) { title, key in
                    Picker(title, selection: Binding(get: { WidgetDayNavigation.timeout(key: key) }, set: {
                        Preferences.defaults.set($0, forKey: "widgetReset.\(key)")
                        revision += 1; WidgetReloader.schedule()
                    })) {
                        Text("Off").tag(0.0); Text("30 seconds").tag(30.0); Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0)
                    }
                }
            } footer: { Text("After your last day or page tap, return to the default day and first page. Applies to all copies of each widget layout. iOS may delay the reset.") }
        }.navigationTitle("Widget Auto-Reset").id(revision)
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        List {
            LabeledContent("New event", value: "⌘N")
            LabeledContent("New reminder", value: "⇧⌘N")
            LabeledContent("Quick Add", value: "⌘K")
            LabeledContent("Search", value: "⌘F")
            LabeledContent("Today", value: "⌘T")
            LabeledContent("Weekly planner", value: "⇧⌘P")
            LabeledContent("Previous / next", value: "⌘← / ⌘→")
            LabeledContent("Settings", value: "⌘,")
            Text("The Navigate menu also lists shortcuts for each calendar view.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Keyboard Shortcuts")
    }
}

struct ContactDateSelectionView: View {
    @ObservedObject var model: AgendaModel
    @State private var revision = 0
    @State private var query = ""
    @State private var alerts = Preferences.defaults.object(forKey: PlanningPreferences.contactAlerts) as? Int ?? -1
    @State private var alertError: String?
    private var groups: [(String, [ContactDateRecord])] {
        Dictionary(grouping: ContactDates.allRecords.filter { query.isEmpty || "\($0.name) \($0.label)".localizedCaseInsensitiveContains(query) }, by: \.contactID)
            .values.map { ($0.first?.name ?? "Contact", $0.sorted { $0.label < $1.label }) }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
    var body: some View {
        List {
            Section {
                Picker("Advance alerts at 9 AM", selection: $alerts) {
                    Text("Off").tag(-1); Text("On the date").tag(0); Text("1 day before").tag(1); Text("1 week before").tag(7)
                }.onChange(of: alerts) { _, value in
                    Task {
                        if value >= 0 {
                            do {
                                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else { alerts = -1; alertError = "Allow LotsOfEvents notifications in system Settings."; return }
                            } catch { alerts = -1; alertError = error.localizedDescription; return }
                        }
                        Preferences.defaults.set(value, forKey: PlanningPreferences.contactAlerts)
                        model.scheduleRefresh()
                    }
                }
                Text("Alerts cover the next available dates and refresh when the app refreshes. Keep opening LotsOfEvents occasionally to schedule later dates.").font(.footnote).foregroundStyle(.secondary)
                if let alertError { Text(alertError).foregroundStyle(.red) }
                Button("Show All Dates") { Preferences.defaults.removeObject(forKey: PlanningPreferences.hiddenContactDates); changed() }
                Button("Hide All Dates") { Preferences.defaults.set(ContactDates.allRecords.map(\.id), forKey: PlanningPreferences.hiddenContactDates); changed() }
            }
            ForEach(groups, id: \.1.first!.contactID) { name, dates in
                Section {
                    Toggle("All dates for \(name)", isOn: Binding(get: { dates.allSatisfy { PlanningPreferences.contactIsVisible($0.id) } }, set: { value in dates.forEach { PlanningPreferences.setContact($0.id, visible: value) }; changed() }))
                    ForEach(dates) { record in
                        Toggle(isOn: Binding(get: { PlanningPreferences.contactIsVisible(record.id) }, set: { PlanningPreferences.setContact(record.id, visible: $0); changed() })) {
                            Label(record.label, systemImage: record.symbol)
                        }
                    }
                } header: { Text(name) }
            }
        }
        .navigationTitle("Contacts & Occasions").searchable(text: $query)
        .id(revision)
    }
    private func changed() { revision += 1; model.scheduleRefresh(); WidgetReloader.schedule() }
}

@MainActor enum ContactOccasionAlerts {
    private static var revision = 0
    private static var pendingUpdate: Task<Void, Never>?
    static func update() async {
        revision += 1
        let current = revision
        let previous = pendingUpdate
        previous?.cancel()
        let task = Task { @MainActor in
            await previous?.value
            guard current == revision else { return }
            await reconcile(current: current)
        }
        pendingUpdate = task
        await task.value
    }
    private static func reconcile(current: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard current == revision else { return }
        let prefix = "contact-occasion-"
        let existing = pending.filter { $0.identifier.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier))
        let lead = Preferences.defaults.object(forKey: PlanningPreferences.contactAlerts) as? Int ?? -1
        guard lead >= 0, ContactDates.enabled, ContactDateSync.allowed else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus), current == revision else { return }
        let calendar = Calendar.current
        let now = Date.now
        let end = calendar.date(byAdding: .year, value: 1, to: now)!
        let candidates = ContactDates.items(in: DateInterval(start: calendar.startOfDay(for: now), end: end)).compactMap { item -> (AgendaItem, Date)? in
            guard let day = calendar.date(byAdding: .day, value: -lead, to: item.date),
                  let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day), fire > now else { return nil }
            return (item, fire)
        }.sorted { $0.1 < $1.1 }
        // Respect the system limit and leave space for time-to-leave notifications.
        let capacity = min(12, max(0, 56 - pending.filter { !$0.identifier.hasPrefix(prefix) }.count))
        for (item, fire) in candidates.prefix(capacity) {
            guard current == revision else { return }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.date.formatted(date: .complete, time: .omitted)
            content.sound = .default
            content.userInfo = ["contactDateID": item.contactDateID ?? "", "contactDateTimestamp": item.date.timeIntervalSince1970]
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            try? await center.add(UNNotificationRequest(identifier: prefix + item.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }
}
