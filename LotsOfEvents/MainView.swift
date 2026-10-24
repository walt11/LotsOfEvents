import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

enum AppSheet: Identifiable {
    case sources, newEvent(Date), event(EKEvent), reminder(EKReminder?, String?)
    var id: String {
        switch self {
        case .sources: return "sources"
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
            if phase == .active { Task { await model.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.refresh() } }
        .onOpenURL { url in
            guard url.scheme == "lotsofevents" else { return }
            if url.host == "new" { model.sheet = .newEvent(.now) }
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
        .sheet(item: $model.sheet, onDismiss: { Task { await model.refresh() } }) { sheet in
            switch sheet {
            case .sources: SourcesView(model: model)
            case .newEvent(let date): EventEditor(store: model.store, startDate: date)
            case .event(let event): EventDetails(event: event)
            case .reminder(let reminder, let list): ReminderEditor(model: model, reminder: reminder, defaultListID: list)
            }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
            if let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder { sheet = .reminder(reminder, nil) }
            else { error = "This reminder no longer exists. Refresh your agenda." }
        } else {
            // Resolve the exact occurrence, rather than another instance of a recurring event.
            let day = Calendar.current.startOfDay(for: item.date)
            let range = DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
            if let event = events(in: range).first(where: {
                "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)" == item.id
            }) { sheet = .event(event) }
            else { error = "This event changed or was removed. Refresh your agenda." }
        }
    }
    func toggle(_ reminder: EKReminder) {
        guard reminder.calendar.allowsContentModifications else { error = "This list is read-only."; return }
        let previous = reminder.isCompleted
        reminder.isCompleted.toggle()
        do { try store.save(reminder, commit: true); Task { await refresh() } }
        catch { reminder.isCompleted = previous; self.error = error.localizedDescription }
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
