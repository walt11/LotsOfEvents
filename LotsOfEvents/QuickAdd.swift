import SwiftUI
import EventKit

struct QuickAddParse: Equatable {
    var title: String
    var date: Date?
    var duration: TimeInterval?
    /// True when the text named a day but no time.
    var allDay = false
}

/// Pulls a date or time out of phrases such as "Lunch with Sam Friday 1pm".
enum QuickAddParser {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeWords = try! NSRegularExpression(pattern: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#, options: .caseInsensitive)
    static func parse(_ text: String, calendar: Calendar = .current) -> QuickAddParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: all), let date = match.date, let range = Range(match.range, in: trimmed) else {
            return QuickAddParse(title: trimmed)
        }
        let phrase = String(trimmed[range])
        // NSDataDetector doesn't report whether a time was given, so look for one in the matched words.
        let timed = timeWords.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
        var title = trimmed.replacingCharacters(in: range, with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        for suffix in [" at", " on", " by", " due", " from"] where title.lowercased().hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return QuickAddParse(title: title, date: timed ? date : calendar.startOfDay(for: date), duration: match.duration > 0 ? match.duration : nil, allDay: !timed)
    }
}

struct QuickAddView: View {
    @ObservedObject var model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var reminder = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var parsed: QuickAddParse { QuickAddParser.parse(text) }
    private var canSave: Bool { !parsed.title.isEmpty && (reminder ? model.reminderAccess : model.calendarAccess) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(reminder ? "Call the pharmacy tomorrow 10am" : "Lunch with Sam Friday 1pm", text: $text)
                        .focused($focused).submitLabel(.done).onSubmit(save)
                    Picker("Add as", selection: $reminder) {
                        Text("Event").tag(false)
                        Text("Reminder").tag(true)
                    }.pickerStyle(.segmented)
                } footer: { Text("Type a title with a day or time, like “tomorrow 3pm” or “next Tuesday”.") }
                if !parsed.title.isEmpty {
                    Section("Preview") {
                        LabeledContent("Title", value: parsed.title)
                        LabeledContent(reminder ? "Due" : "Starts", value: whenText)
                        LabeledContent(reminder ? "List" : "Calendar", value: (reminder ? model.store.defaultCalendarForNewReminders()?.title : model.store.defaultCalendarForNewEvents?.title) ?? "None")
                    }
                }
                if reminder ? !model.reminderAccess : !model.calendarAccess {
                    Text(reminder ? "Connect Reminders to add reminders." : "Connect calendars to add events.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).fontWeight(.semibold).disabled(!canSave) }
            }
            .alert("Unable to add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
            .task {
                // Focusing during the sheet's presentation animation is ignored, so wait for it to settle.
                try? await Task.sleep(for: .milliseconds(450))
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
        .tint(.teal)
    }
    private var eventStart: Date { parsed.date ?? Date.now.roundedUpToHalfHour() }
    private var whenText: String {
        if reminder && parsed.date == nil { return "No date" }
        let date = reminder ? parsed.date! : eventStart
        return parsed.allDay ? date.formatted(date: .complete, time: .omitted) : date.formatted(date: .abbreviated, time: .shortened)
    }
    private func save() {
        guard canSave else { return }
        do {
            if reminder {
                guard let list = model.store.defaultCalendarForNewReminders() else { error = "Choose a default list in the Reminders app."; return }
                let item = EKReminder(eventStore: model.store)
                item.title = parsed.title
                item.calendar = list
                if let due = parsed.date {
                    item.dueDateComponents = ReminderDates.components(due, timed: !parsed.allDay)
                    if !parsed.allDay { item.addAlarm(EKAlarm(absoluteDate: due)) }
                }
                try model.store.save(item, commit: true)
            } else {
                guard let calendar = model.store.defaultCalendarForNewEvents else { error = "Choose a default calendar in Settings → Calendar."; return }
                let event = EKEvent(eventStore: model.store)
                event.title = parsed.title
                event.calendar = calendar
                event.isAllDay = parsed.allDay
                event.startDate = eventStart
                event.endDate = eventStart.addingTimeInterval(parsed.allDay ? 0 : parsed.duration ?? 3600)
                try model.store.save(event, span: .thisEvent, commit: true)
            }
            model.scheduleRefresh()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
