import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

enum AppSheet: Identifiable {
    case sources, newEvent(Date), event(EKEvent), reminder(EKReminder?, String?), quickAdd
    var id: String {
        switch self {
        case .sources: return "sources"
        case .quickAdd: return "quick-add"
        case .newEvent(let date): return "new-\(date.timeIntervalSince1970)"
        case .event(let event): return "event-\(event.eventIdentifier ?? "")-\(event.startDate.timeIntervalSince1970)"
        case .reminder(let reminder, let list): return "reminder-\(reminder?.calendarItemIdentifier ?? list ?? "new")"
        }
    }
}

struct MainView: View {
    @StateObject private var model = AgendaModel()
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            CalendarHome(model: model).tabItem { Label("Calendar", systemImage: "calendar") }.tag(0)
            AgendaView(model: model).tabItem { Label("Upcoming", systemImage: "list.bullet.rectangle") }.tag(1)
            RemindersHome(model: model).tabItem { Label("Reminders", systemImage: "checklist") }.tag(2)
        }
        .tint(.teal)
        .task { await model.refresh() }
        .onChange(of: phase) { _, phase in
            if phase == .active { model.scheduleRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in model.scheduleRefresh() }
        .onOpenURL { url in
            guard url.scheme == "lotsofevents" else { return }
            if url.host == "new" { model.sheet = .newEvent(Date.now.roundedUpToHalfHour()) }
            else if url.host == "quick-add" { tab = 1; model.sheet = .quickAdd }
            else if url.host == "reminders" { tab = 2 }
            else if url.host == "new-reminder" {
                tab = 2
                Task {
                    await model.refresh()
                    if model.reminderAccess { model.sheet = .reminder(nil, nil) }
                }
            }
            else { tab = 1 }
        }
        .sheet(item: $model.sheet, onDismiss: { model.scheduleRefresh() }) { sheet in
            switch sheet {
            case .sources: SourcesView(model: model)
            case .newEvent(let date): EventEditor(store: model.store, startDate: date)
            case .event(let event): EventDetails(event: event)
            case .reminder(let reminder, let list): ReminderEditor(model: model, reminder: reminder, defaultListID: list)
            case .quickAdd: QuickAddView(model: model)
            }
        }
        .overlay(alignment: .bottom) {
            if let undo = model.undo {
                UndoToast(undo: undo) { model.undo = nil }
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.undo?.id)
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil; model.errorOffersSettings = false } })) {
            Button("OK", role: .cancel) {}
            if model.errorOffersSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } message: { Text(model.error ?? "") }
    }
}

extension AgendaModel {
    var calendarAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var reminderAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func events(in range: DateInterval) -> [EKEvent] {
        guard calendarAccess else { return [] }
        let selected = calendars.filter { Preferences.selected($0.calendarIdentifier, reminders: false) }
        guard !selected.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: selected))
            .sorted { $0.startDate < $1.startDate }
    }
    func open(_ item: AgendaItem) {
        if item.reminder {
            if let reminder = store.calendarItem(withIdentifier: item.sourceID ?? item.id) as? EKReminder { sheet = .reminder(reminder, nil) }
            else { error = "This reminder no longer exists. Refresh your agenda." }
        } else {
            // Resolve the exact occurrence, rather than another instance of a recurring event.
            let day = Calendar.current.startOfDay(for: item.date)
            let range = DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
            if let event = events(in: range).first(where: {
                "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)" == (item.sourceID ?? item.id)
            }) { sheet = .event(event) }
            else { error = "This event changed or was removed. Refresh your agenda." }
        }
    }
    func toggle(_ reminder: EKReminder, offerUndo: Bool = true) {
        guard reminder.calendar.allowsContentModifications else { error = "This list is read-only."; return }
        let previous = reminder.isCompleted
        reminder.isCompleted.toggle()
        do {
            try store.save(reminder, commit: true)
            if offerUndo {
                let title = reminder.title ?? "Reminder"
                undo = UndoAction(message: reminder.isCompleted ? "Completed “\(title)”" : "Reopened “\(title)”") { [weak self] in
                    self?.toggle(reminder, offerUndo: false)
                }
            }
            scheduleRefresh()
        }
        catch { reminder.isCompleted = previous; self.error = error.localizedDescription }
    }
    /// Deletes a reminder, keeping a copy so Undo can recreate it (with a new identifier).
    func delete(_ reminder: EKReminder) throws {
        let snapshot = ReminderSnapshot(reminder)
        try store.remove(reminder, commit: true)
        undo = UndoAction(message: "Deleted “\(snapshot.title)”") { [weak self] in
            guard let self else { return }
            do { try snapshot.restore(in: self.store); self.scheduleRefresh() }
            catch { self.error = error.localizedDescription }
        }
        scheduleRefresh()
    }
}

struct ReminderSnapshot {
    let title: String
    let notes: String?
    let url: URL?
    let listID: String
    let priority: Int
    let completed: Bool
    let due: DateComponents?
    let start: DateComponents?
    let rules: [EKRecurrenceRule]?
    let alarms: [EKAlarm]?
    init(_ reminder: EKReminder) {
        title = reminder.title ?? "Reminder"
        notes = reminder.notes
        url = reminder.url
        listID = reminder.calendar.calendarIdentifier
        priority = reminder.priority
        completed = reminder.isCompleted
        due = reminder.dueDateComponents
        start = reminder.startDateComponents
        rules = reminder.recurrenceRules?.compactMap { $0.copy() as? EKRecurrenceRule }
        alarms = reminder.alarms?.compactMap { $0.copy() as? EKAlarm }
    }
    func restore(in store: EKEventStore) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        reminder.calendar = store.calendar(withIdentifier: listID) ?? store.defaultCalendarForNewReminders()
        reminder.priority = priority
        reminder.dueDateComponents = due
        reminder.startDateComponents = start
        reminder.recurrenceRules = rules
        reminder.alarms = alarms
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }
}

struct UndoToast: View {
    let undo: UndoAction
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(undo.message).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
            Button("Undo") { undo.perform(); close() }.fontWeight(.semibold)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .tint(.teal)
        .padding(.horizontal)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { close() }
        }
    }
}

struct EventDetails: UIViewControllerRepresentable {
    let event: EKEvent
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let view = EKEventViewController()
        view.event = event
        view.allowsEditing = event.calendar.allowsContentModifications
        view.allowsCalendarPreview = true
        view.delegate = context.coordinator
        view.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.close))
        return UINavigationController(rootViewController: view)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, EKEventViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        @objc func close() { dismiss() }
        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) { dismiss() }
    }
}

struct AccessCard: View {
    let title: String
    let description: String
    let connect: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock.shield")
        } description: { Text(description) } actions: {
            Button("Connect", action: connect).buttonStyle(.borderedProminent)
        }
    }
}
