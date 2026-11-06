import SwiftUI
import EventKit

/// The two ways the Reminders tab can be laid out.
enum ReminderLayout: String, CaseIterable, Identifiable {
    case focus, lists
    var id: String { rawValue }
    var title: String { self == .focus ? "Focus" : "By list" }
    var symbol: String { self == .focus ? "sun.max" : "rectangle.stack" }
}

enum FocusScope: String, CaseIterable, Identifiable {
    case today = "Today", upcoming = "Upcoming", anytime = "Anytime", done = "Done"
    var id: String { rawValue }
}

/// The Reminders tab's chip bar: the Focus scopes, then the By List cards.
enum ReminderMode: String, CaseIterable {
    case today = "Today", upcoming = "Upcoming", anytime = "Anytime", done = "Done", lists = "Lists"
    init(_ scope: FocusScope) { self = ReminderMode(rawValue: scope.rawValue) ?? .today }
    var scope: FocusScope? { FocusScope(rawValue: rawValue) }
}

/// Sections of the Focus view's Today scope, in display order.
enum FocusBucket: Int, CaseIterable {
    case overdue, morning, afternoon, tonight, anytime
    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .morning: return "This morning"
        case .afternoon: return "This afternoon"
        case .tonight: return "Tonight"
        case .anytime: return "Any time today"
        }
    }
}

enum FocusGrouping {
    /// Where an open reminder falls in Today, or nil when it isn't due by the end of today.
    static func bucket(due: Date?, timed: Bool, now: Date, calendar: Calendar = .current) -> FocusBucket? {
        guard let due else { return nil }
        let today = calendar.startOfDay(for: now)
        guard due < calendar.date(byAdding: .day, value: 1, to: today)! else { return nil }
        if due < today || (timed && due < now) { return .overdue }
        guard timed else { return .anytime }
        switch calendar.component(.hour, from: due) {
        case ..<12: return .morning
        case ..<17: return .afternoon
        default: return .tonight
        }
    }
    /// Done today out of everything due by today, for the header's progress bar.
    static func progress(done: Int, open: Int) -> Double { done + open == 0 ? 0 : Double(done) / Double(done + open) }
}

/// Reminder order in both views: dated reminders by due time first, then undated ones in the order they were added,
/// so a new reminder without a date lands at the end of its list.
enum ReminderOrder {
    static func precedes(_ a: EKReminder, _ b: EKReminder, byPriority: Bool) -> Bool {
        precedes(due: ReminderDates.due(a), priority: a.priority, created: a.creationDate, title: a.title ?? "",
                 before: ReminderDates.due(b), b.priority, b.creationDate, b.title ?? "", byPriority: byPriority)
    }
    static func precedes(due: Date?, priority: Int, created: Date?, title: String,
                         before otherDue: Date?, _ otherPriority: Int, _ otherCreated: Date?, _ otherTitle: String,
                         byPriority: Bool) -> Bool {
        func rank(_ p: Int) -> Int { p == 0 ? 10 : p }
        if byPriority && rank(priority) != rank(otherPriority) { return rank(priority) < rank(otherPriority) }
        let a = due ?? .distantFuture, b = otherDue ?? .distantFuture
        if a != b { return a < b }
        // Same due time, or both undated: oldest first. Unsaved items have no creation date and go last.
        let ca = created ?? .distantFuture, cb = otherCreated ?? .distantFuture
        if ca != cb { return ca < cb }
        return title.localizedStandardCompare(otherTitle) == .orderedAscending
    }
}

/// Short due labels: "3:00 PM" or "Today", "Yesterday", "Tomorrow 9:00 AM", "Fri", "Oct 30".
enum ReminderDueText {
    static func label(due: Date, timed: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = due.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return timed ? time : "Today"
        case -1: return "Yesterday"
        case 1: return timed ? "Tomorrow \(time)" : "Tomorrow"
        case 2...6: return due.formatted(.dateTime.weekday(.abbreviated)) + (timed ? " \(time)" : "")
        case -6 ... -2: return due.formatted(.dateTime.weekday(.abbreviated))
        default: return due.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// One reminder: completion circle, title, list, and a due pill. Tapping the title opens the editor.
struct ReminderLine: View {
    @ObservedObject var model: AgendaModel
    let reminder: EKReminder
    var showList = true
    /// Shows the first line of notes and the reminder's link under the title.
    var showNotes = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    var body: some View {
        // At accessibility text sizes the due pill moves under the title instead of squeezing it.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        HStack(spacing: 4) {
            Button { model.toggle(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(reminder.calendarColor).frame(width: 40, height: 44)
            }
            .buttonStyle(.borderless).disabled(!reminder.isWritable)
            .accessibilityLabel(reminder.isCompleted ? "Mark \(reminder.title ?? "reminder") incomplete" : "Complete \(reminder.title ?? "reminder")")
            Button { model.inspect(reminder) } label: {
                layout {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if reminder.priority != 0 { Text(ReminderPriority.badge(reminder.priority)).foregroundStyle(GalleryPalette.warning).fontWeight(.bold) }
                            Text(reminder.title ?? "Reminder").font(.subheadline.weight(.medium))
                                .strikethrough(reminder.isCompleted).foregroundStyle(reminder.isCompleted ? GalleryPalette.muted : GalleryPalette.ink)
                        }
                        if showList || reminder.hasRecurrenceRules {
                            HStack(spacing: 5) {
                                if showList {
                                    Circle().fill(reminder.calendarColor).frame(width: 6, height: 6)
                                    Text(reminder.calendarTitle)
                                }
                                if reminder.hasRecurrenceRules { Image(systemName: "repeat").accessibilityLabel("Repeats") }
                            }.font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1)
                        }
                        if showNotes, let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                            Text(notes).font(.caption).foregroundStyle(GalleryPalette.muted).lineLimit(2)
                        }
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    if !reminder.isCompleted, let due = ReminderDates.due(reminder) {
                        let late = ReminderDates.isOverdue(reminder)
                        Text(ReminderDueText.label(due: due, timed: reminder.dueDateComponents?.hour != nil))
                            .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(late ? GalleryPalette.alert : GalleryPalette.ink)
                            .background(late ? GalleryPalette.alert.opacity(0.1) : GalleryPalette.line.opacity(0.5), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showNotes, let url = reminder.url {
                Button { openURL(url) } label: {
                    Image(systemName: "link").font(.footnote.weight(.semibold)).foregroundStyle(GalleryPalette.accent).frame(width: 36, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open link \(url.host() ?? url.absoluteString)")
            }
        }
        .draggable(ReminderDrag.payload(reminder.calendarItemIdentifier))
    }
}

// MARK: - Focus (B)

struct ReminderFocusView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Open reminders already narrowed by the chosen lists and search.
    let open: [EKReminder]
    /// Reminders completed today, narrowed the same way.
    let doneToday: [EKReminder]
    /// Older completed reminders, loaded only after "Show earlier".
    let doneEarlier: [EKReminder]
    @Binding var scope: FocusScope
    @Binding var showEarlier: Bool
    let sortByPriority: Bool
    /// Where the inline field saves; nil uses the default list.
    let targetListID: String?
    @State private var draft = ""
    @State private var options = InlineReminderDraft()
    @State private var showDone = false
    @FocusState private var draftFocused: Bool

    private func sorted(_ items: [EKReminder]) -> [EKReminder] {
        items.sorted { ReminderOrder.precedes($0, $1, byPriority: sortByPriority) }
    }
    private var dueByToday: [EKReminder] {
        open.filter { FocusGrouping.bucket(due: ReminderDates.due($0), timed: $0.dueDateComponents?.hour != nil, now: .now) != nil }
    }
    /// (title, count label, reminders, title color) per visible section.
    private var sections: [(id: String, title: String, items: [EKReminder], late: Bool)] {
        let calendar = Calendar.current
        switch scope {
        case .today:
            let grouped = Dictionary(grouping: dueByToday) {
                FocusGrouping.bucket(due: ReminderDates.due($0), timed: $0.dueDateComponents?.hour != nil, now: .now)!
            }
            return FocusBucket.allCases.compactMap { bucket in
                grouped[bucket].map { (String(bucket.rawValue), bucket.title, sorted($0), bucket == .overdue) }
            }
        case .upcoming:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            let future = open.filter { (ReminderDates.due($0) ?? .distantPast) >= tomorrow }
            let byDay = Dictionary(grouping: future) { calendar.startOfDay(for: ReminderDates.due($0)!) }
            return byDay.keys.sorted().map { day in
                let title = calendar.isDate(day, inSameDayAs: tomorrow) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide).month().day())
                return (day.description, title, sorted(byDay[day]!), false)
            }
        case .anytime:
            let undated = open.filter { ReminderDates.due($0) == nil }
            return undated.isEmpty ? [] : [("anytime", "No date", sorted(undated), false)]
        case .done:
            var result: [(String, String, [EKReminder], Bool)] = []
            if !doneToday.isEmpty { result.append(("today", "Done today", doneToday, false)) }
            if showEarlier && !doneEarlier.isEmpty { result.append(("earlier", "Earlier", doneEarlier, false)) }
            return result
        }
    }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            if model.loading && open.isEmpty && doneToday.isEmpty {
                ProgressView("Loading reminders…").listRowBackground(Color.clear)
            } else if sections.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: scope == .done ? "checkmark.circle" : "sun.max", description: Text(emptyDetail))
                    .listRowBackground(Color.clear)
            }
            ForEach(sections, id: \.id) { section in
                Section {
                    ForEach(section.items, id: \.calendarItemIdentifier) { reminder in
                        ReminderLine(model: model, reminder: reminder)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 12))
                            .listRowBackground(GalleryPalette.card)
                            .swipeActions(edge: .leading) {
                                Button(reminder.isCompleted ? "Reopen" : "Complete") { model.toggle(reminder) }.tint(accent)
                            }
                            .swipeActions(edge: .trailing) { SnoozeButtons(model: model, reminder: reminder) }
                    }
                } header: {
                    SectionHeader(title: section.title, trailing: "\(section.items.count)", tint: section.late ? GalleryPalette.alert : GalleryPalette.muted)
                }
            }
            if scope == .today && !doneToday.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showDone) {
                        ForEach(doneToday, id: \.calendarItemIdentifier) { reminder in
                            ReminderLine(model: model, reminder: reminder)
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 12))
                        }
                    } label: {
                        SectionHeader(title: "Done today", trailing: "\(doneToday.count)")
                    }
                }.listRowBackground(GalleryPalette.card)
            }
            if scope == .done && !showEarlier {
                Button("Show Earlier Completed Reminders") { showEarlier = true }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(12)
        // The grouped list's default top margin left a gap under the chip bar, as in the Agenda.
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .appRowHeight(48)
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                Spacer()
                let done = doneToday.count, total = doneToday.count + dueByToday.count
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(done) of \(total) done").font(.caption).foregroundStyle(GalleryPalette.muted)
                    ProgressView(value: FocusGrouping.progress(done: done, open: dueByToday.count))
                        .tint(accent).frame(width: 96)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(done) of \(total) reminders due today are done")
            }
            if scope != .done {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(accent).accessibilityHidden(true)
                    TextField(scope == .today ? "Add for today… “Call mom 6pm”" : "Add a reminder… “Dentist Friday”", text: $draft)
                        .focused($draftFocused).submitLabel(.done).onSubmit(addDraft)
                        .accessibilityLabel("New reminder")
                    if !draft.isEmpty {
                        Button("Add", action: addDraft).font(.subheadline.weight(.semibold))
                    }
                    ReminderOptionsButton(draft: $options, onSheetDismiss: { draftFocused = true })
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(GalleryPalette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
        }
    }
    private var emptyTitle: String {
        switch scope {
        case .today: return "Nothing due today"
        case .upcoming: return "Nothing scheduled"
        case .anytime: return "No undated reminders"
        case .done: return "Nothing completed today"
        }
    }
    private var emptyDetail: String {
        switch scope {
        case .today: return "Add one above, or check Upcoming."
        case .upcoming: return "Reminders with a future due date appear here."
        case .anytime: return "Reminders without a due date appear here."
        case .done: return "Completed reminders appear here."
        }
    }
    /// Saves the inline field as a reminder. In Today, a reminder typed without a date is due today.
    private func addDraft() {
        do {
            if try InlineReminderSaver.save(text: draft, draft: options, defaultToToday: scope == .today, listID: targetListID, model: model) {
                draft = ""
                options = InlineReminderDraft()
            }
        } catch { model.error = error.localizedDescription }
    }
}

// MARK: - Inline add row

/// Choices from an add row's options menu. Anything not chosen falls back to what the typed text says.
struct InlineReminderDraft: Equatable {
    enum Day: Equatable { case today, tomorrow, weekend, nextWeek, custom(Date) }
    var day: Day?
    /// Hour and minute; nil means no time.
    var time: DateComponents?
    var priority = 0
    var isEmpty: Bool { day == nil && time == nil && priority == 0 }

    /// The title and due date to save. Menu choices win over dates typed in the text.
    func resolve(_ text: String, now: Date = .now, calendar: Calendar = .current) -> (title: String, due: Date?, timed: Bool) {
        let parsed = QuickAddParser.parse(text, calendar: calendar)
        guard day != nil || time != nil else { return (parsed.title, parsed.date, parsed.date != nil && !parsed.allDay) }
        let today = calendar.startOfDay(for: now)
        let base: Date
        switch day {
        case nil: base = parsed.date.map { calendar.startOfDay(for: $0) } ?? today
        case .today: base = today
        case .tomorrow: base = calendar.date(byAdding: .day, value: 1, to: today)!
        case .weekend:
            base = calendar.isDateInWeekend(now) ? today
                : calendar.startOfDay(for: calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!)
        case .nextWeek:
            base = calendar.startOfDay(for: calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!)
        case .custom(let date): base = calendar.startOfDay(for: date)
        }
        let resolvedTime = time ?? (parsed.allDay ? nil : parsed.date.map { calendar.dateComponents([.hour, .minute], from: $0) })
        guard let time = resolvedTime, let hour = time.hour else { return (parsed.title, base, false) }
        var due = calendar.date(bySettingHour: hour, minute: time.minute ?? 0, second: 0, of: base)!
        // A time picked with no day means its next occurrence.
        if day == nil && parsed.date == nil && due <= now { due = calendar.date(byAdding: .day, value: 1, to: due)! }
        return (parsed.title, due, true)
    }
}

// MARK: - Options menu for add rows

/// The ••• menu on an add row: date, time, priority, and Clear/Cancel. Shared by By list cards and the Focus field.
struct ReminderOptionsButton: View {
    @AppAccent private var accent
    @Binding var draft: InlineReminderDraft
    var onCancel: (() -> Void)? = nil
    var onSheetDismiss: () -> Void = {}
    @State private var showCustomDate = false
    @State private var customDate = Date.now.roundedUpToHalfHour()
    @State private var customTimed = false
    var body: some View {
        Menu {
            Section("Date") {
                dayButton("Today", .today, symbol: "sun.max")
                dayButton("Tomorrow", .tomorrow, symbol: "sunrise")
                dayButton("This Weekend", .weekend, symbol: "sofa")
                dayButton("Next Week", .nextWeek, symbol: "calendar.badge.clock")
                Button { showCustomDate = true } label: {
                    if case .custom(let date) = draft.day {
                        Label(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: "checkmark")
                    } else {
                        Label("Choose Date…", systemImage: "calendar")
                    }
                }
            }
            Section("Time") {
                timeButton("Morning · 9 AM", hour: 9)
                timeButton("Afternoon · 1 PM", hour: 13)
                timeButton("Evening · 6 PM", hour: 18)
                if draft.time != nil {
                    Button("No Time", systemImage: "clock.badge.xmark") { draft.time = nil }
                }
            }
            Picker(selection: $draft.priority) {
                Text("None").tag(0)
                Text("Low").tag(9)
                Text("Medium").tag(5)
                Text("High").tag(1)
            } label: { Label("Priority", systemImage: "exclamationmark") }
                .pickerStyle(.menu)
            Section {
                if !draft.isEmpty { Button("Clear Options", systemImage: "arrow.uturn.backward") { draft = InlineReminderDraft() } }
                if let onCancel { Button("Cancel", systemImage: "xmark", role: .destructive, action: onCancel) }
            }
        } label: {
            Image(systemName: draft.isEmpty ? "ellipsis.circle" : "ellipsis.circle.fill")
                .font(.title3).foregroundStyle(accent).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Reminder options")
        .sheet(isPresented: $showCustomDate, onDismiss: onSheetDismiss) { customDateSheet }
    }
    private func dayButton(_ title: String, _ day: InlineReminderDraft.Day, symbol: String) -> some View {
        Button { draft.day = draft.day == day ? nil : day } label: {
            Label(title, systemImage: draft.day == day ? "checkmark" : symbol)
        }
    }
    private func timeButton(_ title: String, hour: Int) -> some View {
        Button { draft.time = draft.time?.hour == hour ? nil : DateComponents(hour: hour, minute: 0) } label: {
            Label(title, systemImage: draft.time?.hour == hour ? "checkmark" : "clock")
        }
    }
    private var customDateSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $customDate, displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("Time", isOn: $customTimed)
                if customTimed { DatePicker("Time", selection: $customDate, displayedComponents: .hourAndMinute) }
            }
            .navigationTitle("Due Date").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCustomDate = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        draft.day = .custom(customDate)
                        draft.time = customTimed ? Calendar.current.dateComponents([.hour, .minute], from: customDate) : nil
                        showCustomDate = false
                    }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .tint(accent)
    }
}

/// Saves a new reminder from an add row's text and options.
@MainActor
enum InlineReminderSaver {
    static func save(text: String, draft: InlineReminderDraft, defaultToToday: Bool, listID: String?, model: AgendaModel) throws -> Bool {
        let repeats = QuickAddParser.parse(text).repeats
        var resolved = draft.resolve(text)
        guard !resolved.title.isEmpty else { return false }
        // A repeating reminder needs a due date to repeat from.
        if resolved.due == nil && (defaultToToday || repeats != nil) { resolved.due = Calendar.current.startOfDay(for: .now) }
        let item = EKReminder(eventStore: model.store)
        item.title = resolved.title
        item.calendar = listID.flatMap { model.store.calendar(withIdentifier: $0) } ?? model.store.defaultCalendarForNewReminders()
        item.priority = draft.priority
        if let due = resolved.due {
            item.dueDateComponents = ReminderDates.components(due, timed: resolved.timed)
            AlertDefaults.apply(to: item, due: due, timed: resolved.timed)
        }
        if let repeats { item.addRecurrenceRule(repeats.rule) }
        try model.store.save(item, commit: true)
        model.scheduleRefresh()
        return true
    }
}

// MARK: - By list (C)

struct ReminderCardsView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Open reminders in the shown lists.
    let open: [EKReminder]
    /// The lists to show, in order.
    let lists: [EKCalendar]
    let sortByPriority: Bool
    @State private var expanded: Set<String> = []
    /// The list whose add row is being typed in.
    @State private var addingIn: String?
    @State private var draftText = ""
    @State private var draft = InlineReminderDraft()
    @FocusState private var draftFocused: Bool
    private let preview = 3

    private func items(in list: EKCalendar) -> [EKReminder] {
        open.filter { $0.calendar?.calendarIdentifier == list.calendarIdentifier }
            .sorted { ReminderOrder.precedes($0, $1, byPriority: sortByPriority) }
    }
    /// Lists with open reminders first, then empty ones, each group in the account's order.
    private var shownLists: [EKCalendar] {
        if Preferences.defaults.stringArray(forKey: "reminderListOrder") != nil { return lists }
        return lists.filter { !items(in: $0).isEmpty } + lists.filter { items(in: $0).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if lists.isEmpty {
                        ContentUnavailableView("No reminder lists", systemImage: "checklist", description: Text("Create a list in Apple Reminders, or choose lists with the filter button."))
                    }
                    ForEach(shownLists, id: \.calendarIdentifier) { list in card(list) }
                }
                // Completed reminders slide out instead of vanishing.
                .animation(.snappy, value: open.map(\.calendarItemIdentifier))
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 20)
            }
            .refreshable { await model.refresh() }
            // Keep the row being typed in visible above the keyboard.
            .onChange(of: draftFocused) { _, isFocused in
                guard isFocused, let id = addingIn else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { proxy.scrollTo("add-\(id)", anchor: .center) }
                }
            }
            }
        }
        .background(GalleryPalette.paper)
        // Open a just-created list's card in full.
        .onChange(of: model.lastCreatedListID) { _, id in if let id { withAnimation(.snappy) { _ = expanded.insert(id) } } }
    }

    private func card(_ list: EKCalendar) -> some View {
        let entries = items(in: list)
        let id = list.calendarIdentifier
        let showAll = expanded.contains(id)
        let visible = showAll ? entries : Array(entries.prefix(preview))
        let color = Color(cgColor: list.cgColor)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(list.title).font(.headline).foregroundStyle(GalleryPalette.ink).lineLimit(2)
                Spacer()
                Text("\(entries.count) open").font(.footnote.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            // Touch and hold a list's name to rename, recolor, or delete it.
            .contextMenu {
                if list.allowsContentModifications {
                    Button("Edit or Delete List…", systemImage: "pencil") { model.sheet = .editList(list) }
                }
            }
            .frame(minHeight: 48)
            if entries.isEmpty && !list.allowsContentModifications {
                Divider()
                Text("All done").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(minHeight: 44)
            }
            ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                Divider().padding(.leading, 44)
                ReminderLine(model: model, reminder: reminder, showList: false)
                    .padding(.leading, 4).padding(.trailing, 12)
                    .contextMenu { SnoozeButtons(model: model, reminder: reminder) }
            }
            if list.allowsContentModifications {
                Divider().padding(.leading, 44)
                Group {
                    if addingIn == id { editRow(list, color: color) } else { addRow(list, color: color) }
                }.id("add-\(id)")
            }
            if entries.count > preview {
                Divider()
                Button(showAll ? "Show less" : "Show all \(entries.count)") {
                    withAnimation(.snappy) { if showAll { expanded.remove(id) } else { expanded.insert(id) } }
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(GalleryPalette.line, lineWidth: 0.5) }
    }

    private func addRow(_ list: EKCalendar, color: Color) -> some View {
        Button { startAdding(in: list.calendarIdentifier) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(GalleryPalette.muted.opacity(0.5)).frame(width: 40, height: 44)
                Text("Add reminder").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                Spacer()
            }
            .padding(.leading, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add reminder to \(list.title)")
    }

    private func editRow(_ list: EKCalendar, color: Color) -> some View {
        let resolved = draft.resolve(draftText)
        let summary = [
            resolved.due.map { ReminderDueText.label(due: $0, timed: resolved.timed) },
            draft.priority == 0 ? nil : ReminderPriority.badge(draft.priority)
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 4) {
            Image(systemName: "circle").font(.title3).foregroundStyle(color.opacity(0.5))
                .frame(width: 40, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField("New reminder", text: $draftText)
                    .font(.subheadline.weight(.medium))
                    .focused($draftFocused).submitLabel(.done)
                    .onSubmit { commit(to: list) }
                if !summary.isEmpty {
                    Text(summary).font(.caption2.weight(.semibold)).foregroundStyle(accent)
                }
            }
            Spacer(minLength: 4)
            ReminderOptionsButton(draft: $draft, onCancel: stopAdding, onSheetDismiss: { draftFocused = true })
        }
        .padding(.leading, 4).padding(.trailing, 4)
    }

    private func startAdding(in id: String) {
        addingIn = id
        // Expand the card so reminders added here stay in view.
        expanded.insert(id)
        draftText = ""
        draft = InlineReminderDraft()
        Task { @MainActor in
            // Focus once the field exists.
            try? await Task.sleep(for: .milliseconds(80))
            draftFocused = true
        }
    }
    private func stopAdding() {
        addingIn = nil
        draftText = ""
        draft = InlineReminderDraft()
        draftFocused = false
    }
    /// Saves the typed reminder into the list and leaves the row open for the next one; Return on an empty row closes it.
    private func commit(to list: EKCalendar) {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stopAdding(); return }
        do {
            if try InlineReminderSaver.save(text: draftText, draft: draft, defaultToToday: false, listID: list.calendarIdentifier, model: model) {
                draftText = ""
                draft = InlineReminderDraft()
                draftFocused = true
            }
        } catch { model.error = error.localizedDescription }
    }
}


/// Reorders app presentation only; calendar contents and account membership stay intact.
struct ReminderListOrderView: View {
    @ObservedObject var model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.lists, id: \.calendarIdentifier) { list in
                        HStack {
                            Circle().fill(Color(cgColor: list.cgColor)).frame(width: 10, height: 10)
                            VStack(alignment: .leading) {
                                Text(list.title)
                                Text(list.source.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onMove(perform: model.moveReminderLists)
                } footer: { Text("Drag the handles to arrange your lists. Changes are saved automatically in this app.") }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Lists")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 300, minHeight: 360)
    }
}
