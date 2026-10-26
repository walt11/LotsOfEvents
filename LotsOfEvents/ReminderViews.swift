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

/// Sections of the Focus view's Today scope, in display order.
enum FocusBucket: Int, CaseIterable {
    case overdue, morning, afternoon, tonight, anytime
    var title: String {
        switch self {
        case .overdue: return "OVERDUE"
        case .morning: return "THIS MORNING"
        case .afternoon: return "THIS AFTERNOON"
        case .tonight: return "TONIGHT"
        case .anytime: return "ANY TIME TODAY"
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
    var body: some View {
        HStack(spacing: 4) {
            Button { model.toggle(reminder) } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(reminder.calendarColor).frame(width: 40, height: 44)
            }
            .buttonStyle(.borderless).disabled(!reminder.isWritable)
            .accessibilityLabel(reminder.isCompleted ? "Mark \(reminder.title ?? "reminder") incomplete" : "Complete \(reminder.title ?? "reminder")")
            Button { model.sheet = .reminder(reminder, nil) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if reminder.priority != 0 { Text(ReminderPriority.badge(reminder.priority)).foregroundStyle(.orange).fontWeight(.bold) }
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
                    }
                    Spacer(minLength: 4)
                    if !reminder.isCompleted, let due = ReminderDates.due(reminder) {
                        let late = ReminderDates.isOverdue(reminder)
                        Text(ReminderDueText.label(due: due, timed: reminder.dueDateComponents?.hour != nil))
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(late ? Color.red : GalleryPalette.ink)
                            .background(late ? Color.red.opacity(0.12) : GalleryPalette.line.opacity(0.5), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
                let title = calendar.isDate(day, inSameDayAs: tomorrow) ? "TOMORROW" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
                return (day.description, title, sorted(byDay[day]!), false)
            }
        case .anytime:
            let undated = open.filter { ReminderDates.due($0) == nil }
            return undated.isEmpty ? [] : [("anytime", "NO DATE", sorted(undated), false)]
        case .done:
            var result: [(String, String, [EKReminder], Bool)] = []
            if !doneToday.isEmpty { result.append(("today", "DONE TODAY", doneToday, false)) }
            if showEarlier && !doneEarlier.isEmpty { result.append(("earlier", "EARLIER", doneEarlier, false)) }
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
                    HStack { Text(section.title); Spacer(); Text("\(section.items.count)") }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(section.late ? Color.red : GalleryPalette.muted)
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
                        Text("DONE TODAY · \(doneToday.count)").font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted)
                    }
                }.listRowBackground(GalleryPalette.card)
            }
            if scope == .done && !showEarlier {
                Button("Show earlier completed reminders") { showEarlier = true }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(12)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .environment(\.defaultMinListRowHeight, 48)
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FocusScope.allCases) { option in
                        Button { scope = option } label: {
                            Text(option.rawValue).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .foregroundStyle(scope == option ? GalleryPalette.paper : GalleryPalette.ink)
                                .background(scope == option ? GalleryPalette.ink : GalleryPalette.card, in: Capsule())
                                .overlay { Capsule().strokeBorder(GalleryPalette.line, lineWidth: scope == option ? 0 : 0.5) }
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(scope == option ? .isSelected : [])
                    }
                }
            }.scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if scope != .done {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(accent).accessibilityHidden(true)
                    TextField(scope == .today ? "Add for today… “Call mom 6pm”" : "Add a reminder… “Dentist Friday”", text: $draft)
                        .focused($draftFocused).submitLabel(.done).onSubmit(addDraft)
                        .accessibilityLabel("New reminder")
                    if !draft.isEmpty {
                        Button("Add", action: addDraft).font(.subheadline.weight(.semibold))
                    }
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
        var parsed = QuickAddParser.parse(draft)
        guard !parsed.title.isEmpty else { return }
        if parsed.date == nil && scope == .today {
            parsed.date = Calendar.current.startOfDay(for: .now)
            parsed.allDay = true
        }
        do {
            try QuickAddSaver.save(parsed, as: .reminder, in: model.store, calendarID: targetListID)
            draft = ""
            model.scheduleRefresh()
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
        case nil, .today: base = today
        case .tomorrow: base = calendar.date(byAdding: .day, value: 1, to: today)!
        case .weekend:
            base = calendar.isDateInWeekend(now) ? today
                : calendar.startOfDay(for: calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!)
        case .nextWeek:
            base = calendar.startOfDay(for: calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!)
        case .custom(let date): base = calendar.startOfDay(for: date)
        }
        guard let time, let hour = time.hour else { return (parsed.title, base, false) }
        var due = calendar.date(bySettingHour: hour, minute: time.minute ?? 0, second: 0, of: base)!
        // A time picked with no day means its next occurrence.
        if day == nil && due <= now { due = calendar.date(byAdding: .day, value: 1, to: due)! }
        return (parsed.title, due, true)
    }
}

// MARK: - By list (C)

struct ReminderCardsView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Open reminders already narrowed by search.
    let open: [EKReminder]
    /// The lists to show, in order.
    let lists: [EKCalendar]
    let sortByPriority: Bool
    /// One list to show in full; nil shows every list's card.
    @State private var focused: String?
    @State private var expanded: Set<String> = []
    /// The list whose add row is being typed in.
    @State private var addingIn: String?
    @State private var draftText = ""
    @State private var draft = InlineReminderDraft()
    @FocusState private var draftFocused: Bool
    @State private var showCustomDate = false
    @State private var customDate = Date.now.roundedUpToHalfHour()
    @State private var customTimed = false
    private let preview = 3

    private func items(in list: EKCalendar) -> [EKReminder] {
        open.filter { $0.calendar?.calendarIdentifier == list.calendarIdentifier }
            .sorted { ReminderOrder.precedes($0, $1, byPriority: sortByPriority) }
    }
    /// Lists with open reminders first, then empty ones, each group in the account's order.
    private var shownLists: [EKCalendar] {
        let visible = focused.map { id in lists.filter { $0.calendarIdentifier == id } } ?? lists
        return visible.filter { !items(in: $0).isEmpty } + visible.filter { items(in: $0).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "All · \(open.filter { item in lists.contains { $0.calendarIdentifier == item.calendar?.calendarIdentifier } }.count)", color: nil, selected: focused == nil) { focused = nil }
                    ForEach(lists, id: \.calendarIdentifier) { list in
                        chip(title: list.title, color: Color(cgColor: list.cgColor), selected: focused == list.calendarIdentifier) {
                            focused = focused == list.calendarIdentifier ? nil : list.calendarIdentifier
                        }
                    }
                }.padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if lists.isEmpty {
                        ContentUnavailableView("No reminder lists", systemImage: "checklist", description: Text("Create a list in Apple Reminders, or choose lists with the filter button."))
                    }
                    ForEach(shownLists, id: \.calendarIdentifier) { list in card(list) }
                }
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
        // Show a just-created list on its own; an empty new list would otherwise sit at the bottom.
        .onChange(of: model.lastCreatedListID) { _, id in if let id { withAnimation(.snappy) { focused = id } } }
        .sheet(isPresented: $showCustomDate, onDismiss: { draftFocused = true }) { customDateSheet }
    }

    private func chip(title: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .foregroundStyle(selected ? GalleryPalette.paper : GalleryPalette.ink)
            .background(selected ? GalleryPalette.ink : GalleryPalette.card, in: Capsule())
            .overlay { Capsule().strokeBorder(GalleryPalette.line, lineWidth: selected ? 0 : 0.5) }
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func card(_ list: EKCalendar) -> some View {
        let entries = items(in: list)
        let id = list.calendarIdentifier
        let showAll = focused == id || expanded.contains(id)
        let visible = showAll ? entries : Array(entries.prefix(preview))
        let color = Color(cgColor: list.cgColor)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(list.title).font(.headline).foregroundStyle(GalleryPalette.ink).lineLimit(1)
                Spacer()
                Text("\(entries.count) OPEN").font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted)
            }
            .padding(.horizontal, 14)
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
            if entries.count > preview && focused != id {
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
            Menu { optionsMenu } label: {
                Image(systemName: draft.isEmpty ? "ellipsis.circle" : "ellipsis.circle.fill")
                    .font(.title3).foregroundStyle(accent).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reminder options")
        }
        .padding(.leading, 4).padding(.trailing, 4)
    }

    @ViewBuilder private var optionsMenu: some View {
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
            Button("Cancel", systemImage: "xmark", role: .destructive) { stopAdding() }
        }
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
        let resolved = draft.resolve(draftText)
        guard !resolved.title.isEmpty else { return }
        let item = EKReminder(eventStore: model.store)
        item.title = resolved.title
        item.calendar = list
        item.priority = draft.priority
        if let due = resolved.due {
            item.dueDateComponents = ReminderDates.components(due, timed: resolved.timed)
            AlertDefaults.apply(to: item, due: due, timed: resolved.timed)
        }
        do {
            try model.store.save(item, commit: true)
            draftText = ""
            draft = InlineReminderDraft()
            draftFocused = true
            model.scheduleRefresh()
        } catch { model.error = error.localizedDescription }
    }
}
