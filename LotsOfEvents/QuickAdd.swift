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
    @State var reminder = false
    /// A day chosen before opening (a widget's +); used unless the text or a day shortcut names another.
    var presetDay: Date? = nil
    @State private var error: String?
    @State private var dayPhrase: String?
    @State private var timePhrase: String?
    /// The chosen calendar or list; empty means the account default.
    @State private var targetID = ""
    @FocusState private var focused: Bool
    private var parsed: QuickAddParse {
        var result = QuickAddParser.parse([text, dayPhrase, timePhrase].compactMap { $0 }.joined(separator: " "))
        guard let presetDay, dayPhrase == nil else { return result }
        let calendar = Calendar.current
        if let date = result.date, !result.allDay, !QuickAddParser.namesDay(text) {
            // A time on its own ("3pm", or a time shortcut) lands on the preset day.
            let time = calendar.dateComponents([.hour, .minute], from: date)
            result.date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: presetDay)
        } else if result.date == nil {
            result.date = calendar.startOfDay(for: presetDay)
            result.allDay = true
        }
        return result
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(QuickAddShortcuts.days(), id: \.label) { chip in
                                shortcut(chip.label, selected: dayPhrase == chip.phrase) { dayPhrase = dayPhrase == chip.phrase ? nil : chip.phrase }
                            }
                            Divider().frame(height: 20)
                            ForEach(QuickAddShortcuts.times, id: \.label) { chip in
                                shortcut(chip.label, selected: timePhrase == chip.phrase) { timePhrase = timePhrase == chip.phrase ? nil : chip.phrase }
                            }
                        }
                    }.scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    Picker("Add as", selection: $reminder) {
                        Text("Event").tag(false)
                        Text("Reminder").tag(true)
                    }.pickerStyle(.segmented)
                    Picker(reminder ? "List" : "Calendar", selection: $targetID) {
                        Text("Default (\(defaultTargetName))").tag("")
                        ForEach(targets, id: \.calendarIdentifier) { target in
                            // Menus tint SF Symbols, so draw the dot in its own color to keep each list recognizable.
                            Label { Text(target.title) } icon: {
                                Image(uiImage: UIImage(systemName: "circle.fill")!.withTintColor(UIColor(cgColor: target.cgColor), renderingMode: .alwaysOriginal))
                            }.tag(target.calendarIdentifier)
                        }
                    }
                } footer: { Text("Type or dictate a title with a day or time, like “Gym every Monday 6pm”, or tap a shortcut.") }
                if !parsed.title.isEmpty {
                    Section("Preview") {
                        LabeledContent("Title", value: parsed.title)
                        LabeledContent(reminder ? "Due" : "Starts", value: whenText)
                        if let repeats = parsed.repeats { LabeledContent("Repeats", value: repeats.title) }
                    }
                }
                if reminder ? !model.reminderAccess : !model.calendarAccess {
                    Text(reminder ? "Connect Reminders to add reminders." : "Connect calendars to add events.").foregroundStyle(.secondary)
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .tint(accent)
    }
    private func shortcut(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.footnote.weight(.medium)).padding(.horizontal, 11).frame(minHeight: 30)
                .foregroundStyle(selected ? _accent.contrastingText : .primary)
                .background(selected ? accent : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var eventStart: Date { QuickAddSaver.eventStart(parsed) }
    private var whenText: String {
        if reminder && parsed.date == nil { return "No date" }
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
