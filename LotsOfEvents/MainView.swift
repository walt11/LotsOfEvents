import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

enum AppSheet: Identifiable {
    case sources, newEvent(Date), event(EKEvent), reminder(EKReminder?, String?), quickAdd(reminder: Bool)
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
    @AppAccent private var accent
    @StateObject private var model = AgendaModel()
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            if sizeClass == .regular { sidebarLayout } else { phoneLayout }
        }
        .background(GalleryPalette.paper)
        .foregroundStyle(GalleryPalette.ink)
        .scrollContentBackground(.hidden)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).scheme)
        .tint(accent)
        .task { await model.refresh() }
        .onChange(of: phase) { _, phase in
            if phase == .active { model.scheduleRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in model.scheduleRefresh() }
        .onOpenURL { url in
            guard url.scheme == "lotsofevents" else { return }
            if url.host == "new" { model.sheet = .newEvent(Date.now.roundedUpToHalfHour()) }
            else if url.host == "quick-add" {
                // The widget's + opens straight into Quick Add; `?type=reminder` starts in reminder mode.
                model.sheet = .quickAdd(reminder: url.query?.contains("type=reminder") == true)
            }
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
            case .quickAdd(let reminder): QuickAddView(model: model, reminder: reminder)
            }
        }
        .overlay(alignment: .bottom) {
            if let undo = model.undo {
                UndoToast(undo: undo) { model.undo = nil }
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.undo?.id)
        // A light confirmation whenever a reminder is completed, reopened, snoozed, or deleted.
        .sensoryFeedback(.success, trigger: model.undo?.id) { _, new in new != nil }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil; model.errorOffersSettings = false } })) {
            Button("OK", role: .cancel) {}
            if model.errorOffersSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } message: { Text(model.error ?? "") }
    }
    private static let sections: [(title: String, symbol: String)] = [("Calendar", "calendar"), ("Agenda", "list.bullet.rectangle"), ("Reminders", "checklist"), ("Settings", "gearshape")]
    private var tabs: some View {
        TabView(selection: $tab) {
            CalendarHome(model: model).toolbar(.hidden, for: .tabBar).tag(0)
            AgendaView(model: model).toolbar(.hidden, for: .tabBar).tag(1)
            RemindersHome(model: model).toolbar(.hidden, for: .tabBar).tag(2)
            SourcesView(model: model, embedded: true).toolbar(.hidden, for: .tabBar).tag(3)
        }
    }
    private var phoneLayout: some View {
        VStack(spacing: 0) {
            tabs
            HStack(spacing: 0) {
                bottomTab(index: 0)
                bottomTab(index: 1)
                addButton.frame(maxWidth: .infinity)
                bottomTab(index: 2)
                bottomTab(index: 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .gallerySurface(radius: 22)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
        }
    }
    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: Binding<Int?>(get: { tab }, set: { if let index = $0 { select(index) } })) {
                ForEach(Self.sections.indices, id: \.self) { index in
                    Label(Self.sections[index].title, systemImage: Self.sections[index].symbol).tag(index)
                }
            }
            .navigationTitle("LotsOfEvents")
            .safeAreaInset(edge: .bottom) {
                Button { quickAdd() } label: {
                    Label("Quick Add", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(_accent.contrastingText)
                .contextMenu { fullEditorButtons }
                .padding()
            }
        } detail: {
            // A paged TabView inside the detail column hides each section's navigation bar, so show the section directly.
            switch tab {
            case 0: CalendarHome(model: model)
            case 1: AgendaView(model: model)
            case 2: RemindersHome(model: model)
            default: SourcesView(model: model, embedded: true)
            }
        }
        // Keep the sidebar beside the content in portrait too, instead of floating over a dimmed view.
        .navigationSplitViewStyle(.balanced)
    }
    /// Tap opens Quick Add; touch and hold offers the full editors.
    private var addButton: some View {
        Button { quickAdd() } label: {
            Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(_accent.contrastingText)
                .frame(width: 50, height: 50).background(accent, in: Circle())
                .shadow(color: accent.opacity(0.15), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu { fullEditorButtons }
        .accessibilityLabel("Quick add")
        .accessibilityHint("Touch and hold for the full event or reminder editor.")
    }
    @ViewBuilder private var fullEditorButtons: some View {
        Button("New Event…", systemImage: "calendar.badge.plus") { model.sheet = .newEvent(tab == 0 ? model.calendarCreationDate : Date.now.roundedUpToHalfHour()) }
        Button("New Reminder…", systemImage: "checklist") { model.sheet = .reminder(nil, model.activeReminderList) }
    }
    private func quickAdd() { model.sheet = .quickAdd(reminder: tab == 2) }
    private func select(_ index: Int) {
        if TabReselect.returnsToToday(selecting: index, from: tab) {
            if index == 0 { model.calendarReturnToToday += 1 } else { model.agendaReturnToToday += 1 }
        }
        tab = index
    }
    private func bottomTab(index: Int) -> some View {
        let (title, symbol) = Self.sections[index]
        return Button { select(index) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .foregroundStyle(tab == index ? accent : Color.secondary)
            .background(tab == index ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
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
        guard reminder.isWritable else { error = "This list is read-only."; return }
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
    @AppAccent private var accent
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
        .tint(accent)
        .padding(.horizontal)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { close() }
        }
    }
}

struct EventDetails: UIViewControllerRepresentable {
    @AppAccent private var accent
    let event: EKEvent
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let view = EKEventViewController()
        view.event = event
        view.view.tintColor = UIColor(accent)
        view.allowsEditing = event.isWritable
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

/// Tapping the Calendar (0) or Agenda (1) tab while it is selected jumps back to today.
enum TabReselect {
    static func returnsToToday(selecting index: Int, from current: Int) -> Bool { index == current && index <= 1 }
}
