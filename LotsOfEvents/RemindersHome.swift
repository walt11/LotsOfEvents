import SwiftUI
import EventKit
import WidgetKit

struct RemindersHome: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @AppStorage("reminderLayout") private var layout = ReminderLayout.focus
    @AppStorage("reminderFocusScope") private var scope = FocusScope.today
    /// Lists shown in the Reminders tab, saved between launches; empty means all lists.
    @AppStorage("reminderTabLists") private var savedListIDs = ""
    @AppStorage("reminderSortByPriority") private var sortByPriority = false
    @State private var search = ""
    @State private var showingSearch = false
    @State private var showEarlier = false
    @FocusState private var searchFocused: Bool
    /// The chosen lists that still exist, so a deleted list can't hide everything.
    private var listIDs: Set<String> {
        let chosen = Set(savedListIDs.split(separator: ",").map(String.init))
        return chosen.intersection(model.lists.map(\.calendarIdentifier))
    }
    private func setList(_ id: String, included: Bool) {
        var ids = listIDs
        if included { ids.insert(id) } else { ids.remove(id) }
        savedListIDs = ids.sorted().joined(separator: ",")
    }
    /// New reminders go to the shown list when exactly one is chosen.
    private var singleListID: String? { listIDs.count == 1 ? listIDs.first : nil }
    private var shownLists: [EKCalendar] { listIDs.isEmpty ? model.lists : model.lists.filter { listIDs.contains($0.calendarIdentifier) } }
    /// Applies the list choice and search; reminders whose list was deleted are dropped.
    private func narrowed(_ items: [EKReminder]) -> [EKReminder] {
        items.filter { reminder in
            guard let id = reminder.calendar?.calendarIdentifier else { return false }
            if !listIDs.isEmpty && !listIDs.contains(id) { return false }
            return search.isEmpty || [reminder.title, reminder.notes, reminder.calendarTitle].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private var needsCompleted: Bool { layout == .focus && scope == .done && showEarlier }
    var body: some View {
        let open = narrowed(model.reminders.filter { !$0.isCompleted })
        NavigationStack {
            Group {
                if !model.reminderAccess {
                    AccessCard(title: "Make room for what matters", description: "Connect Apple Reminders to manage all your lists, including undated and overdue tasks.") { Task { await model.request(.reminder) } }
                } else {
                    VStack(spacing: 0) {
                        if showingSearch {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search reminders and notes", text: $search).focused($searchFocused)
                                    .submitLabel(.search).onSubmit { searchFocused = false }
                                Button("Close search", systemImage: "xmark.circle.fill") {
                                    search = ""; showingSearch = false
                                }.labelStyle(.iconOnly).foregroundStyle(.secondary).frame(width: 44, height: 44)
                            }.padding(.leading, 12).gallerySurface(radius: 12)
                                .padding(.horizontal, 16).padding(.bottom, 4)
                        }
                        switch layout {
                        case .focus:
                            let todayIDs = Set(model.completedToday.map(\.calendarItemIdentifier))
                            let earlier = model.reminders.filter { $0.isCompleted && !todayIDs.contains($0.calendarItemIdentifier) }
                                .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                            ReminderFocusView(model: model, open: open,
                                              doneToday: narrowed(model.completedToday).sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) },
                                              doneEarlier: narrowed(earlier), scope: $scope, showEarlier: $showEarlier,
                                              sortByPriority: sortByPriority, targetListID: singleListID)
                        case .lists:
                            ReminderCardsView(model: model, open: open, lists: shownLists, sortByPriority: sortByPriority)
                        }
                    }
                    .background(GalleryPalette.paper)
                }
            }
            .navigationTitle("Reminders")
            .galleryTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .tint(accent)
            .onAppear { model.includeCompleted = needsCompleted; model.activeReminderList = singleListID }
            .onChange(of: singleListID) { _, value in model.activeReminderList = value }
            .onChange(of: needsCompleted) { _, value in model.includeCompleted = value }
            .onChange(of: scope) { _, value in if value != .done { showEarlier = false } }
            // A new list joins an active list filter so it isn't hidden by it.
            .onChange(of: model.lastCreatedListID) { _, id in
                if let id, !listIDs.isEmpty { setList(id, included: true) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Layout", selection: $layout) {
                            ForEach(ReminderLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    } label: {
                        Label("Reminder view: \(layout.title)", systemImage: layout.symbol)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Search reminders", systemImage: "magnifyingglass") {
                        showingSearch = true; searchFocused = true
                    }
                    Menu {
                        Section("Lists") {
                            Button("All lists", systemImage: listIDs.isEmpty ? "checkmark" : "") { savedListIDs = "" }
                            // Toggles stay open so several lists can be picked in one visit.
                            ForEach(model.lists, id: \.calendarIdentifier) { list in
                                Toggle("\(list.title) · \(list.source.title)", isOn: Binding(
                                    get: { listIDs.contains(list.calendarIdentifier) },
                                    set: { setList(list.calendarIdentifier, included: $0) }))
                            }
                        }
                        Section("Sort") {
                            Picker("Sort", selection: $sortByPriority) {
                                Text("Due date").tag(false)
                                Text("Priority").tag(true)
                            }
                        }
                        Section {
                            Button("New List…", systemImage: "plus") { model.sheet = .newList }
                        }
                    } label: {
                        Label("Filter and sort", systemImage: listIDs.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuActionDismissBehavior(.disabled)
                    .accessibilityValue(listIDs.isEmpty ? "All lists" : "\(listIDs.count) lists")
                }
            }
        }
    }
}

/// EventKit priorities: 1–4 high, 5 medium, 6–9 low, 0 none.
enum ReminderPriority {
    static func normalized(_ priority: Int) -> Int {
        switch priority { case 0: return 0; case 1...4: return 1; case 5: return 5; default: return 9 }
    }
    static func badge(_ priority: Int) -> String {
        switch normalized(priority) { case 1: return "!!!"; case 5: return "!!"; default: return "!" }
    }
}

enum ReminderRepeat: String, CaseIterable {
    case keep = "Keep existing", never = "Never", daily = "Daily", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
    var frequency: EKRecurrenceFrequency? {
        switch self { case .daily: return .daily; case .weekly: return .weekly; case .monthly: return .monthly; case .yearly: return .yearly; default: return nil }
    }
}

enum ReminderAlert: String, CaseIterable {
    case keep = "Keep existing", none = "None", atTime = "At due time", minutes5 = "5 minutes before", minutes15 = "15 minutes before"
    case minutes30 = "30 minutes before", hour = "1 hour before", day = "1 day before"
    var offset: TimeInterval? {
        switch self {
        case .atTime: return 0
        case .minutes5: return -300
        case .minutes15: return -900
        case .minutes30: return -1800
        case .hour: return -3600
        case .day: return -86400
        default: return nil
        }
    }
    /// The editor's starting choice for a new timed reminder, from Settings → Notifications.
    static var defaultForNew: ReminderAlert {
        switch AlertDefaults.reminder {
        case .none: return .none
        case .atTime: return .atTime
        case .minutes5: return .minutes5
        case .minutes15: return .minutes15
        case .minutes30: return .minutes30
        case .hour1: return .hour
        case .day1: return .day
        }
    }
}

struct ReminderEditor: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    let reminder: EKReminder?
    let defaultListID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var link = ""
    @State private var listID = ""
    @State private var hasDate = false
    @State private var hasTime = false
    @State private var due = Date.now
    @State private var priority = 0
    @State private var repeatRule = ReminderRepeat.never
    @State private var alert = ReminderAlert.none
    @State private var completed = false
    @State private var initialized = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var saving = false
    private var writableLists: [EKCalendar] { model.lists.filter(\.allowsContentModifications) }
    private var readOnly: Bool { reminder.map { !$0.isWritable } ?? false }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).font(.headline)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
                    TextField("URL", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("List") {
                    Picker("List", selection: $listID) {
                        if readOnly, let reminder, let list = reminder.calendar { Text(list.title).tag(list.calendarIdentifier) }
                        ForEach(writableLists, id: \.calendarIdentifier) { Text("\($0.title) · \($0.source.title)").tag($0.calendarIdentifier) }
                    }
                }
                Section("Schedule") {
                    Toggle("Date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                        Toggle("Time", isOn: Binding(get: { hasTime }, set: { enabled in
                            hasTime = enabled
                            // Leave "Keep existing" alone so toggling Time doesn't replace a reminder's alarms.
                            if alert != .keep { alert = enabled ? ReminderAlert.defaultForNew : .none }
                        }))
                        if hasTime { DatePicker("At", selection: $due, displayedComponents: .hourAndMinute) }
                        Picker("Repeat", selection: $repeatRule) {
                            ForEach(ReminderRepeat.allCases.filter { $0 != .keep || reminder != nil }, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if hasTime {
                            Picker("Alert", selection: $alert) {
                                ForEach(ReminderAlert.allCases.filter { $0 != .keep || reminder != nil }, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        }
                    }
                }
                Section {
                    Picker("Priority", selection: $priority) {
                        Text("None").tag(0); Text("Low").tag(9); Text("Medium").tag(5); Text("High").tag(1)
                    }
                    if reminder != nil { Toggle("Completed", isOn: $completed) }
                }
                if readOnly { Text("This list is read-only. You can view this reminder but cannot change it.").foregroundStyle(.secondary) }
                if reminder != nil && !readOnly {
                    Section { Button("Delete Reminder", role: .destructive) { confirmDelete = true } }
                }
            }
            .disabled(saving || readOnly)
            .navigationTitle(reminder == nil ? "New Reminder" : "Reminder Details")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(readOnly ? "Done" : "Cancel") { dismiss() } }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save).fontWeight(.semibold)
                            .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || listID.isEmpty)
                    }
                }
            }
            .onAppear(perform: initialize)
            .alert("Unable to save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
            .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Reminder", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes it from Apple Reminders and your synced devices. Repeating reminders will also stop repeating.") }
        }.tint(accent)
    }
    private func initialize() {
        guard !initialized else { return }
        initialized = true
        listID = defaultListID ?? model.store.defaultCalendarForNewReminders()?.calendarIdentifier ?? writableLists.first?.calendarIdentifier ?? ""
        if !writableLists.contains(where: { $0.calendarIdentifier == listID }) { listID = writableLists.first?.calendarIdentifier ?? "" }
        guard let reminder else { return }
        title = reminder.title ?? ""
        notes = reminder.notes ?? ""
        link = reminder.url?.absoluteString ?? ""
        listID = reminder.calendar?.calendarIdentifier ?? listID
        hasDate = reminder.dueDateComponents != nil
        hasTime = reminder.dueDateComponents?.hour != nil
        due = ReminderDates.due(reminder) ?? .now
        priority = ReminderPriority.normalized(reminder.priority)
        repeatRule = .keep
        alert = .keep
        completed = reminder.isCompleted
    }
    private func save() {
        guard !saving, !readOnly else { return }
        guard let calendar = model.store.calendar(withIdentifier: listID), calendar.allowsContentModifications else { error = "Choose a writable reminder list."; return }
        let url: URL?
        if link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { url = nil }
        else {
            guard let parsed = URL(string: link), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { error = "Enter a complete website URL starting with https:// or http://."; return }
            url = parsed
        }
        let target: EKReminder
        if let reminder {
            guard let current = model.store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { error = "This reminder was deleted. Close this editor and refresh."; return }
            target = current
        } else { target = EKReminder(eventStore: model.store) }
        saving = true
        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes = notes.isEmpty ? nil : notes
        target.url = url
        target.calendar = calendar
        target.priority = priority
        ReminderSchedule.apply(to: target, due: hasDate ? due : nil, timed: hasTime, repeatRule: repeatRule, alert: alert)
        // A new date-only reminder gets the day's alert when that's turned on in Settings.
        if reminder == nil && hasDate && !hasTime { AlertDefaults.apply(to: target, due: due, timed: false) }
        target.isCompleted = completed
        do {
            try model.store.save(target, commit: true)
            model.scheduleRefresh()
            dismiss()
        } catch {
            _ = target.refresh()
            self.error = error.localizedDescription
            saving = false
        }
    }
    private func delete() {
        guard let reminder, !readOnly else { return }
        do { try model.delete(reminder); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}


enum ReminderSchedule {
    static func apply(to reminder: EKReminder, due: Date?, timed: Bool, repeatRule: ReminderRepeat, alert: ReminderAlert) {
        let previousDue = ReminderDates.due(reminder)
        let locationAlarms = reminder.alarms?.filter { $0.structuredLocation != nil } ?? []
        reminder.dueDateComponents = due.map { ReminderDates.components($0, timed: timed) }
        guard let due else {
            // Editing an undated reminder must not erase existing location alerts.
            if previousDue != nil {
                reminder.startDateComponents = nil
                reminder.recurrenceRules = nil
                reminder.alarms = locationAlarms.isEmpty ? nil : locationAlarms
            }
            return
        }
        if repeatRule != .keep {
            reminder.recurrenceRules = repeatRule.frequency.map { [EKRecurrenceRule(recurrenceWith: $0, interval: 1, end: nil)] }
            reminder.startDateComponents = repeatRule.frequency == nil ? nil : reminder.dueDateComponents
        } else if reminder.hasRecurrenceRules {
            if let start = reminder.startDateComponents, let startDate = (start.calendar ?? .current).date(from: start), startDate > due {
                reminder.startDateComponents = reminder.dueDateComponents
            }
        }
        if alert != .keep {
            var alarms = locationAlarms
            if timed, let offset = alert.offset { alarms.append(EKAlarm(absoluteDate: due.addingTimeInterval(offset))) }
            reminder.alarms = alarms.isEmpty ? nil : alarms
        } else if let previousDue, due != previousDue {
            reminder.alarms = reminder.alarms?.map { alarm in
                guard alarm.structuredLocation == nil, let absolute = alarm.absoluteDate, let updated = alarm.copy() as? EKAlarm else { return alarm }
                updated.absoluteDate = absolute.addingTimeInterval(due.timeIntervalSince(previousDue))
                return updated
            }
        }
    }
}
