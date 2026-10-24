import SwiftUI
import EventKit
import WidgetKit

enum ReminderFilter: String, CaseIterable {
    case today = "Today", scheduled = "Scheduled", all = "All", completed = "Completed"
    var symbol: String {
        switch self { case .today: return "calendar"; case .scheduled: return "calendar.badge.clock"; case .all: return "tray.full"; case .completed: return "checkmark.circle" }
    }
}

enum ReminderDates {
    static func due(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return (components.calendar ?? Calendar.current).date(from: components)
    }
    static func isOverdue(_ reminder: EKReminder, now: Date = .now) -> Bool {
        guard !reminder.isCompleted, let due = due(reminder) else { return false }
        return reminder.dueDateComponents?.hour == nil ? due < Calendar.current.startOfDay(for: now) : due < now
    }
    static func components(_ date: Date, timed: Bool, calendar: Calendar = .current) -> DateComponents {
        var result = calendar.dateComponents(timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        result.calendar = calendar
        if timed { result.timeZone = calendar.timeZone }
        return result
    }
}

struct RemindersHome: View {
    @ObservedObject var model: AgendaModel
    @State private var filter = ReminderFilter.all
    @State private var listID: String?
    @State private var search = ""
    @State private var showCompleted = false
    @State private var sortByPriority = false
    private var filtered: [EKReminder] {
        model.reminders.filter { reminder in
            if let listID {
                guard reminder.calendar.calendarIdentifier == listID, showCompleted || !reminder.isCompleted else { return false }
            } else if !matches(reminder, filter: filter) { return false }
            return search.isEmpty || [reminder.title, reminder.notes, reminder.calendar.title].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if sortByPriority && $0.priority != $1.priority {
                return ($0.priority == 0 ? 10 : $0.priority) < ($1.priority == 0 ? 10 : $1.priority)
            }
            let a = ReminderDates.due($0) ?? .distantFuture
            let b = ReminderDates.due($1) ?? .distantFuture
            if a != b { return a < b }
            return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
        }
    }
    private var title: String { model.lists.first(where: { $0.calendarIdentifier == listID })?.title ?? filter.rawValue }
    var body: some View {
        NavigationStack {
            Group {
                if !model.reminderAccess {
                    AccessCard(title: "Make room for what matters", description: "Connect Apple Reminders to manage all your lists, including undated and overdue tasks.") { Task { await model.request(.reminder) } }
                } else {
                    List {
                        Section {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(ReminderFilter.allCases, id: \.self) { option in
                                    Button { filter = option; listID = nil } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack { Image(systemName: option.symbol); Spacer(); Text("\(model.reminders.filter { matches($0, filter: option) }.count)").font(.title2.bold()) }
                                            Text(option.rawValue).font(.subheadline.weight(.semibold))
                                        }.padding(12).foregroundStyle(listID == nil && filter == option ? Color.white : Color.primary)
                                            .background(listID == nil && filter == option ? Color.teal : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                    }.buttonStyle(.plain)
                                }
                            }.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }.listRowBackground(Color.clear)
                        Section {
                            Menu {
                                Button("All lists") { listID = nil }
                                ForEach(model.lists, id: \.calendarIdentifier) { list in
                                    Button("\(list.title) · \(list.source.title)") { listID = list.calendarIdentifier }
                                }
                            } label: { Label(listID == nil ? "Choose a list" : title, systemImage: "list.bullet") }
                            if listID != nil { Toggle("Show completed", isOn: $showCompleted) }
                        }
                        Section(title) {
                            if model.loading && model.reminders.isEmpty { ProgressView("Loading reminders…") }
                            else if filtered.isEmpty { ContentUnavailableView("Nothing here", systemImage: "checkmark.circle", description: Text(search.isEmpty ? "Add a reminder or choose another view." : "No reminders match your search.")) }
                            ForEach(filtered, id: \.calendarItemIdentifier) { reminder in
                                reminderRow(reminder)
                                    .swipeActions(edge: .leading) {
                                        Button(reminder.isCompleted ? "Reopen" : "Complete") { model.toggle(reminder) }.tint(.teal)
                                    }
                            }
                        }
                    }.refreshable { await model.refresh() }
                }
            }
            .navigationTitle("Reminders")
            .searchable(text: $search, prompt: "Search reminders and notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Sources", systemImage: "slider.horizontal.3") { model.sheet = .sources } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortByPriority) {
                            Text("Due date").tag(false)
                            Text("Priority").tag(true)
                        }
                    } label: { Label("Sort reminders", systemImage: "arrow.up.arrow.down") }
                    Button("New reminder", systemImage: "plus") { model.sheet = .reminder(nil, listID) }
                        .disabled(!model.reminderAccess || !model.lists.contains(where: \.allowsContentModifications))
                }
            }
        }
    }
    private func matches(_ reminder: EKReminder, filter: ReminderFilter) -> Bool {
        switch filter {
        case .all: return !reminder.isCompleted
        case .completed: return reminder.isCompleted
        case .scheduled: return !reminder.isCompleted && ReminderDates.due(reminder) != nil
        case .today:
            guard !reminder.isCompleted, let due = ReminderDates.due(reminder) else { return false }
            return due < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        }
    }
    private func reminderRow(_ reminder: EKReminder) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.toggle(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(Color(cgColor: reminder.calendar.cgColor)).frame(width: 28, height: 32)
            }.buttonStyle(.borderless).disabled(!reminder.calendar.allowsContentModifications)
                .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Complete \(reminder.title ?? "reminder")")
            Button { model.sheet = .reminder(reminder, nil) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        if reminder.priority != 0 { Text(reminder.priority <= 4 ? "!!!" : reminder.priority <= 6 ? "!!" : "!").foregroundStyle(.orange).fontWeight(.bold) }
                        Text(reminder.title ?? "Reminder").strikethrough(reminder.isCompleted).foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    if let notes = reminder.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 6) {
                        Text(reminder.calendar.title).foregroundStyle(.secondary)
                        if let due = ReminderDates.due(reminder) {
                            Text(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened))
                                .foregroundStyle(ReminderDates.isOverdue(reminder) ? Color.red : Color.secondary)
                        }
                        if reminder.hasRecurrenceRules { Image(systemName: "repeat").foregroundStyle(.secondary) }
                    }.font(.caption)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

enum ReminderRepeat: String, CaseIterable {
    case keep = "Keep existing", never = "Never", daily = "Daily", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly"
    var frequency: EKRecurrenceFrequency? {
        switch self { case .daily: return .daily; case .weekly: return .weekly; case .monthly: return .monthly; case .yearly: return .yearly; default: return nil }
    }
}

enum ReminderAlert: String, CaseIterable {
    case keep = "Keep existing", none = "None", atTime = "At due time", hour = "1 hour before", day = "1 day before"
    var offset: TimeInterval? {
        switch self { case .atTime: return 0; case .hour: return -3600; case .day: return -86400; default: return nil }
    }
}

struct ReminderEditor: View {
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
    private var readOnly: Bool { reminder.map { !$0.calendar.allowsContentModifications } ?? false }
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
                        if readOnly, let reminder { Text(reminder.calendar.title).tag(reminder.calendar.calendarIdentifier) }
                        ForEach(writableLists, id: \.calendarIdentifier) { Text("\($0.title) · \($0.source.title)").tag($0.calendarIdentifier) }
                    }
                }
                Section("Schedule") {
                    Toggle("Date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                        Toggle("Time", isOn: Binding(get: { hasTime }, set: { enabled in
                            hasTime = enabled
                            alert = enabled ? .atTime : .none
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
        }.tint(.teal)
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
        listID = reminder.calendar.calendarIdentifier
        hasDate = reminder.dueDateComponents != nil
        hasTime = reminder.dueDateComponents?.hour != nil
        due = ReminderDates.due(reminder) ?? .now
        priority = reminder.priority == 0 ? 0 : reminder.priority <= 4 ? 1 : reminder.priority <= 6 ? 5 : 9
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
        target.isCompleted = completed
        do {
            try model.store.save(target, commit: true)
            Task { await model.refresh() }
            dismiss()
        } catch {
            _ = target.refresh()
            self.error = error.localizedDescription
            saving = false
        }
    }
    private func delete() {
        guard let reminder, !readOnly else { return }
        do { try model.store.remove(reminder, commit: true); Task { await model.refresh() }; dismiss() }
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
