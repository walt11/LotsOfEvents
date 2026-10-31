import SwiftUI
import EventKit

struct QuickAddView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @StateObject private var dictation = QuickAddDictation()
    @State private var dictationPrefix = ""
    @Environment(\.scenePhase) private var phase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State var reminder = false
    /// A day chosen before opening (a widget's +); used unless the text or a day shortcut names another.
    var presetDay: Date? = nil
    @State private var error: String?
    @State private var chosenDay: Date?
    @State private var noDueDate = false
    @State private var chosenTime: DateComponents?
    @State private var timeOverride: Bool?
    @State private var choosingDate = false
    @State private var choosingTime = false
    @State private var pickerDate = Date.now
    /// The chosen calendar or list; empty means the account default.
    @State private var targetID = ""
    @FocusState private var focused: Bool
    private var parsed: QuickAddParse {
        QuickAddResolution.resolve(text, presetDay: presetDay, chosenDay: chosenDay,
                                   chosenTime: chosenTime, timed: timeOverride, noDueDate: reminder && noDueDate)
    }
    private var targets: [EKCalendar] { (reminder ? model.lists : model.calendars).filter(\.allowsContentModifications) }
    private var defaultTargetName: String { (reminder ? model.store.defaultCalendarForNewReminders()?.title : model.store.defaultCalendarForNewEvents?.title) ?? "None" }
    private var canSave: Bool { !parsed.title.isEmpty && (reminder ? model.reminderAccess : model.calendarAccess) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(reminder ? "Call the pharmacy tomorrow 10am" : "Lunch with Sam Friday 1pm", text: $text)
                        .focused($focused).submitLabel(.done).onSubmit(save)
                        .disabled(dictation.active)
                    Button {
                        if dictation.active { dictation.stop() }
                        else {
                            focused = false
                            dictationPrefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await dictation.start() }
                        }
                    } label: {
                        Label(dictation.active ? (dictation.listening ? "Listening… Tap to stop" : "Cancel dictation") : "Dictate", systemImage: dictation.active ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(dictation.active ? Color.red : accent)
                    }
                    interpretation
                } footer: { Text("Type or dictate naturally. Adjust the details below before adding.") }
                if !parsed.title.isEmpty {
                    Section {
                        Text(parsed.title).font(.headline)
                        if let repeats = parsed.repeats { Label(repeats.title, systemImage: "repeat").font(.caption).foregroundStyle(.secondary) }
                        if reminder && noDueDate && QuickAddParser.parse(text).repeats != nil {
                            Text("Repeating tasks need a due date. This task will not repeat.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if reminder ? !model.reminderAccess : !model.calendarAccess {
                    Text(reminder ? "Connect Reminders to add reminders." : "Connect Calendar to add events.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).fontWeight(.semibold).disabled(!canSave) }
            }
            .alert("Unable to add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
        .onChange(of: dictation.transcript) { _, words in
            guard !words.isEmpty else { return }
            text = dictationPrefix.isEmpty ? words : dictationPrefix + " " + words
        }
        .onChange(of: dictation.error) { _, message in if let message { error = message } }
        // Reminders start in the list being viewed in the Reminders tab, when exactly one is shown.
        .onChange(of: reminder) { _, isReminder in targetID = isReminder ? (model.activeReminderList ?? "") : "" }
        .onAppear { if reminder { targetID = model.activeReminderList ?? "" } }
        .onChange(of: phase) { _, value in if value == .background { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .task {
            // Focusing during the sheet's presentation animation is ignored, so wait for it to settle.
            try? await Task.sleep(for: .milliseconds(450))
            focused = true
        }
        // A medium detent is unavailable in compact-height windows (landscape or a folded pose).
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.medium])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .tint(accent)
    }
    private var interpretation: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                  ? [GridItem(.flexible())]
                  : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Menu {
                    Picker("Add as", selection: $reminder) { Text("Event").tag(false); Text("Reminder").tag(true) }
                } label: { option("Type", value: reminder ? "Reminder" : "Event", symbol: reminder ? "checklist" : "calendar") }
                Menu {
                    if reminder {
                        Button("No due date") { noDueDate = true; chosenDay = nil; chosenTime = nil; timeOverride = nil }
                    }
                    Button("Today") { noDueDate = false; chosenDay = Calendar.current.startOfDay(for: .now) }
                    Button("Tomorrow") { noDueDate = false; chosenDay = Calendar.current.date(byAdding: .day, value: 1, to: .now) }
                    Button("Choose Date…") { pickerDate = parsed.date ?? eventStart; choosingDate = true }
                    Button("Use typed date") { noDueDate = false; chosenDay = nil }
                } label: {
                    option("Date", value: reminder && parsed.date == nil ? "No due date" : (parsed.date ?? eventStart).formatted(.dateTime.month(.abbreviated).day()), symbol: "calendar")
                }
                Menu {
                    Button(reminder ? "No time" : "All day") { timeOverride = false; chosenTime = nil }
                    ForEach([9, 12, 18], id: \.self) { hour in
                        Button(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!.formatted(date: .omitted, time: .shortened)) {
                            chosenTime = DateComponents(hour: hour, minute: 0); timeOverride = true
                        }
                    }
                    Button("Choose Time…") { pickerDate = parsed.date ?? eventStart; choosingTime = true }
                    Button("Use typed time") { chosenTime = nil; timeOverride = nil }
                } label: {
                    option("Time", value: parsed.allDay || (reminder && parsed.date == nil) ? (reminder ? "No time" : "All day") : (parsed.date ?? eventStart).formatted(date: .omitted, time: .shortened), symbol: "clock")
                }
                .disabled(reminder && noDueDate)
                Menu {
                    Picker(reminder ? "List" : "Calendar", selection: $targetID) {
                        Text("Default (\(defaultTargetName))").tag("")
                        ForEach(targets, id: \.calendarIdentifier) { target in Text(target.title).tag(target.calendarIdentifier) }
                    }
                } label: { option(reminder ? "List" : "Calendar", value: targets.first { $0.calendarIdentifier == targetID }?.title ?? defaultTargetName, symbol: reminder ? "list.bullet" : "circle.fill") }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosingDate) { dateEditor(time: false) }
        .sheet(isPresented: $choosingTime) { dateEditor(time: true) }
    }
    private func option(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(accent)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }.font(.caption)
            Text(value).font(.subheadline.weight(.medium))
                .foregroundStyle(GalleryPalette.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
    private func dateEditor(time: Bool) -> some View {
        NavigationStack {
            DatePicker(time ? "Time" : "Date", selection: $pickerDate, displayedComponents: time ? .hourAndMinute : .date)
                #if targetEnvironment(macCatalyst)
                .datePickerStyle(.compact)
                #else
                .datePickerStyle(.wheel)
                #endif
                .labelsHidden().padding()
                .navigationTitle(time ? "Choose Time" : "Choose Date").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingDate = false; choosingTime = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if time { chosenTime = Calendar.current.dateComponents([.hour, .minute], from: pickerDate); timeOverride = true }
                            else { noDueDate = false; chosenDay = pickerDate }
                            choosingDate = false; choosingTime = false
                        }
                    }
                }
        }.presentationDetents([.medium])
    }
    private var eventStart: Date { QuickAddSaver.eventStart(parsed) }
    private var whenText: String {
        if reminder && parsed.date == nil { return "No due date" }
        let date = reminder ? parsed.date! : eventStart
        return parsed.allDay ? date.formatted(date: .complete, time: .omitted) : date.formatted(date: .abbreviated, time: .shortened)
    }
    private func save() {
        guard canSave else { return }
        dictation.stop()
        do {
            try QuickAddSaver.save(parsed, as: reminder ? .reminder : .event, in: model.store, calendarID: targetID.isEmpty ? nil : targetID)
            model.scheduleRefresh()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}


/// Merge explicit option choices without losing the date or time detected in the text.
enum QuickAddResolution {
    static func resolve(_ text: String, presetDay: Date? = nil, chosenDay: Date? = nil,
                        chosenTime: DateComponents? = nil, timed: Bool? = nil, noDueDate: Bool = false,
                        now: Date = .now, calendar: Calendar = .current) -> QuickAddParse {
        var result = QuickAddParser.parse(text, calendar: calendar)
        let parsedHasDate = result.date != nil
        let day = chosenDay ?? (!QuickAddParser.namesDay(text) ? presetDay : nil)
        if let day {
            let components = calendar.dateComponents([.hour, .minute], from: result.date ?? day)
            result.date = result.date != nil && !result.allDay
                ? calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: day)
                : calendar.startOfDay(for: day)
            if !parsedHasDate { result.allDay = true }
        }
        if let chosenTime {
            result.date = calendar.date(bySettingHour: chosenTime.hour ?? 9, minute: chosenTime.minute ?? 0, second: 0, of: result.date ?? now)
            result.allDay = false
        }
        if timed == false {
            if let date = result.date { result.date = calendar.startOfDay(for: date) }
            result.allDay = true
        }
        if noDueDate {
            result.date = nil
            result.allDay = true
            result.repeats = nil
        }
        return result
    }
}
