import SwiftUI
import EventKit
import WidgetKit

enum ReminderFilter: String, CaseIterable {
    case today = "Today", scheduled = "Scheduled", all = "All", completed = "Completed"
    var symbol: String {
        switch self { case .today: return "calendar"; case .scheduled: return "calendar.badge.clock"; case .all: return "tray.full"; case .completed: return "checkmark.circle" }
    }
}

struct RemindersHome: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @State private var filter = ReminderFilter.all
    /// Lists shown in the Reminders tab, saved between launches; empty means all lists.
    @AppStorage("reminderTabLists") private var savedListIDs = ""
    @State private var search = ""
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var sortByPriority = false
    @AppStorage("reminderHintViews") private var hintViews = 0
    private var filtered: [EKReminder] {
        model.reminders.filter { reminder in
            if !listIDs.isEmpty, !listIDs.contains(reminder.calendar.calendarIdentifier) { return false }
            guard matches(reminder, filter: filter) else { return false }
            return search.isEmpty || [reminder.title, reminder.notes, reminder.calendarTitle].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
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
    private var listSummary: String {
        switch listIDs.count {
        case 0: return "All lists"
        case 1: return model.lists.first(where: { listIDs.contains($0.calendarIdentifier) })?.title ?? "1 list"
        default: return "\(listIDs.count) lists"
        }
    }
    /// New reminders go to the shown list when exactly one is chosen.
    private var singleListID: String? { listIDs.count == 1 ? listIDs.first : nil }
    private var needsCompleted: Bool { filter == .completed }
    var body: some View {
        let rows = filtered
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
                        Picker("Reminder filter", selection: $filter) {
                            ForEach([ReminderFilter.all, .today, .scheduled, .completed], id: \.self) { option in
                                Text(option == .all ? "Open" : option.rawValue).tag(option)
                            }
                        }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 2)
                        HStack {
                            Menu {
                                Button("All lists", systemImage: listIDs.isEmpty ? "checkmark" : "") { savedListIDs = "" }
                                Divider()
                                // Toggles stay open so several lists can be picked in one visit.
                                ForEach(model.lists, id: \.calendarIdentifier) { list in
                                    Toggle("\(list.title) · \(list.source.title)", isOn: Binding(
                                        get: { listIDs.contains(list.calendarIdentifier) },
                                        set: { setList(list.calendarIdentifier, included: $0) }))
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "list.bullet")
                                    Text(listSummary).lineLimit(1)
                                    Image(systemName: "chevron.down").font(.caption2)
                                }.font(.subheadline)
                            }
                            .menuActionDismissBehavior(.disabled)
                            .accessibilityLabel("Choose reminder lists")
                            .accessibilityValue(listSummary)
                            Spacer()
                            Menu {
                                Picker("Sort", selection: $sortByPriority) {
                                    Text("Due date").tag(false)
                                    Text("Priority").tag(true)
                                }
                            } label: { Label(sortByPriority ? "Priority" : "Due date", systemImage: "arrow.up.arrow.down").font(.caption) }
                        }.padding(.horizontal, 20).frame(minHeight: 44)
                        List {
                            if model.loading && (model.reminders.isEmpty || (needsCompleted && !model.completedLoaded)) {
                                ProgressView("Loading reminders…")
                            } else if rows.isEmpty {
                                ContentUnavailableView(search.isEmpty ? "No reminders" : "No matches", systemImage: "checkmark.circle", description: Text(search.isEmpty ? "Choose another filter or list, or tap + to add a reminder." : "Try another title or note."))
                            }
                            ForEach(ReminderGroup.allCases, id: \.self) { group in
                                let entries = rows.filter { ReminderGroup.group($0) == group }
                                if !entries.isEmpty {
                                    Section {
                                        ForEach(entries, id: \.calendarItemIdentifier) { reminder in
                                            reminderRow(reminder)
                                                .galleryRow()
                                                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                                                .swipeActions(edge: .leading) {
                                                    Button(reminder.isCompleted ? "Reopen" : "Complete") { model.toggle(reminder) }.tint(accent)
                                                }
                                                .swipeActions(edge: .trailing) { SnoozeButtons(model: model, reminder: reminder) }
                                        }
                                    } header: {
                                        HStack { Text(group.rawValue); Spacer(); Text("\(entries.count)") }
                                            .font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted)
                                    }
                                }
                            }
                            // The how-to hint retires after a few visits.
                            if !rows.isEmpty && hintViews < 3 {
                                Text("Tap a circle to complete, a title to edit, or swipe left to snooze.")
                                    .font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
                            }
                        }.listSectionSpacing(10).environment(\.defaultMinListRowHeight, 44)
                            .contentMargins(.top, 4, for: .scrollContent)
                            .refreshable { await model.refresh() }
                    }
                    .background(GalleryPalette.paper)
                    .onAppear { hintViews += 1 }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Search reminders", systemImage: "magnifyingglass") {
                        showingSearch = true; searchFocused = true
                    }
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
        HStack(alignment: .center, spacing: 8) {
            Button { model.toggle(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(reminder.calendarColor).frame(width: 32, height: 30)
            }.buttonStyle(.borderless).disabled(!reminder.isWritable)
                .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Complete \(reminder.title ?? "reminder")")
            Button { model.sheet = .reminder(reminder, nil) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        if reminder.priority != 0 { Text(ReminderPriority.badge(reminder.priority)).foregroundStyle(.orange).fontWeight(.bold) }
                        Text(reminder.title ?? "Reminder").font(.subheadline.weight(.medium)).strikethrough(reminder.isCompleted).foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(reminder.calendarTitle).foregroundStyle(.secondary)
                        if let due = ReminderDates.due(reminder) {
                            Text(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened))
                                .foregroundStyle(ReminderDates.isOverdue(reminder) ? Color.red : Color.secondary)
                        }
                        if reminder.hasRecurrenceRules { Image(systemName: "repeat").foregroundStyle(.secondary) }
                    }.font(.caption2).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

enum ReminderGroup: String, CaseIterable {
    case overdue = "Overdue", today = "Today", upcoming = "Upcoming", anytime = "No date", completed = "Completed"
    static func group(_ reminder: EKReminder, now: Date = .now) -> ReminderGroup {
        if reminder.isCompleted { return .completed }
        guard let due = ReminderDates.due(reminder) else { return .anytime }
        if ReminderDates.isOverdue(reminder, now: now) { return .overdue }
        return Calendar.current.isDate(due, inSameDayAs: now) ? .today : .upcoming
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
    case keep = "Keep existing", none = "None", atTime = "At due time", hour = "1 hour before", day = "1 day before"
    var offset: TimeInterval? {
        switch self { case .atTime: return 0; case .hour: return -3600; case .day: return -86400; default: return nil }
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
                        if readOnly, let reminder { Text(reminder.calendarTitle).tag(reminder.calendar.calendarIdentifier) }
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
                            if alert != .keep { alert = enabled ? .atTime : .none }
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
        listID = reminder.calendar.calendarIdentifier
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
