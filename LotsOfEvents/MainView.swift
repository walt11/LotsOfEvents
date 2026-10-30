import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

enum AppSheet: Identifiable {
    case newEvent(Date, end: Date? = nil), event(EKEvent), duplicate(EKEvent), reminder(EKReminder?, String?), quickAdd(reminder: Bool, day: Date? = nil), newList, editList(EKCalendar), search, sources(reminders: Bool), importICS([ICSEvent]), settings
    var id: String {
        switch self {
        case .newList: return "new-list"
        case .search: return "search"
        case .importICS: return "import-ics"
        case .settings: return "settings"
        case .sources(let reminders): return "sources-\(reminders)"
        case .editList(let list): return "edit-list-\(list.calendarIdentifier)"
        case .quickAdd: return "quick-add"
        case .newEvent(let date, _): return "new-\(date.timeIntervalSince1970)"
        case .duplicate(let event): return "duplicate-\(event.occurrenceKey)"
        case .event(let event): return "event-\(event.eventIdentifier ?? "")-\(event.startDate.timeIntervalSince1970)"
        case .reminder(let reminder, let list): return "reminder-\(reminder?.calendarItemIdentifier ?? list ?? "new")"
        }
    }
}

struct MainView: View {
    @AppAccent private var accent
    @StateObject private var model = AgendaModel()
    @Environment(\.scenePhase) private var phase
    /// Opens to the section chosen in Settings → Tabs.
    @State private var tab = min(2, max(0, Preferences.defaults.integer(forKey: AppTabs.startKey)))
    @AppStorage(AppTabs.orderKey, store: Preferences.defaults) private var tabOrderID = "0,1,2"
    private var tabOrder: [Int] { AppTabs.order(tabOrderID) }
    @AppStorage(AppTextSize.key, store: Preferences.defaults) private var textSizeID = AppTextSize.automatic.rawValue
    @State private var keyboardShown = false
    @AppStorage(AppTheme.key, store: Preferences.defaults) private var themeID = AppTheme.graphite.rawValue
    /// Saving custom colors rebuilds the app even when the Custom theme is already chosen.
    @AppStorage(CustomAppColors.key, store: Preferences.defaults) private var customColorsID = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            MacLayout(model: model)
            #else
            if sizeClass == .regular { sidebarLayout } else { phoneLayout }
            #endif
        }
        // Theme colors are read when views are built, so a new theme rebuilds them.
        .id(themeID + customColorsID)
        .background(GalleryPalette.paper)
        .foregroundStyle(GalleryPalette.ink)
        .scrollContentBackground(.hidden)
        .preferredColorScheme((AppTheme(rawValue: themeID) ?? .graphite).scheme)
        .modifier(TextSizeModifier(size: (AppTextSize(rawValue: textSizeID) ?? .automatic).dynamicType))
        .tint(accent)
        .task { await model.refresh() }
        // After each refresh: the next-event Live Activity, time-to-leave alerts, and the forecast.
        .task(id: model.generation) {
            guard model.calendarAccess else { return }
            let soon = model.events(in: DateInterval(start: .now.addingTimeInterval(-6 * 3600), duration: 30 * 3600))
            await NextEventActivity.update(events: soon)
            await TravelAlerts.update(events: soon)
            await WeatherStore.shared.refresh()
        }
        .onChange(of: phase) { _, phase in
            if phase == .active && Date.now.timeIntervalSince(model.lastRefresh) > 2 { model.scheduleRefresh() }
        }
        // Widgets reload only when calendar or reminder data actually changed (including the app's own saves).
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            model.scheduleRefresh()
            WidgetReloader.schedule()
        }
        .onOpenURL { url in
            if url.isFileURL { model.importCalendarFile(url); return }
            guard url.scheme == "lotsofevents" else { return }
            if url.host == "new" { model.sheet = .newEvent(Date.now.roundedUpToHalfHour()) }
            else if url.host == "quick-add" {
                // The widget's + opens straight into Quick Add; `?type=reminder` starts in reminder mode.
                // `day=<seconds since 1970>` comes from a widget's + and starts Quick Add on that day.
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let day = items.first { $0.name == "day" }?.value.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                model.sheet = .quickAdd(reminder: items.contains { $0.name == "type" && $0.value == "reminder" }, day: day)
            }
            else if url.host == "reminders" {
                tab = 2
                #if targetEnvironment(macCatalyst)
                Preferences.defaults.set(MacView.reminders.rawValue, forKey: "macView")
                #endif
            }
            else if url.host == "calendar" { tab = 0 }
            else { tab = 1 }
        }
        .sheet(item: $model.sheet, onDismiss: { model.scheduleRefresh() }) { sheet in
            switch sheet {
            case .newEvent(let date, let end): EventEditor(store: model.store, startDate: date, endDate: end)
            case .duplicate(let event): EventEditor(store: model.store, startDate: event.startDate, template: event)
            case .event(let event): EventDetailsSheet(event: event) { model.sheet = .duplicate(event) }
            case .reminder(let reminder, let list): ReminderEditor(model: model, reminder: reminder, defaultListID: list)
            case .quickAdd(let reminder, let day): QuickAddView(model: model, reminder: reminder, presetDay: day)
            case .newList: NewListView(model: model)
            case .editList(let list): NewListView(model: model, editing: list)
            case .search: SearchSheet(model: model)
            case .importICS(let events): ICSImportView(store: model.store, events: events)
            case .settings: SourcesView(model: model) { model.sheet = nil }.frame(minWidth: 560, minHeight: 640)
            case .sources(let reminders):
                NavigationStack {
                    SourcePickerView(model: model, reminders: reminders)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.sheet = nil } } }
                }
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
            SourcesView(model: model).toolbar(.hidden, for: .tabBar).tag(3)
        }
    }
    private var phoneLayout: some View {
        VStack(spacing: 0) {
            tabs
            // The bar would ride up on the keyboard and cover what's being typed, so it steps aside while typing.
            if !keyboardShown {
            HStack(spacing: 0) {
                bottomTab(index: tabOrder[0])
                bottomTab(index: tabOrder[1])
                addButton.frame(maxWidth: .infinity)
                bottomTab(index: tabOrder[2])
                bottomTab(index: 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            // Like the system tab bar, labels stop growing at large sizes; touch and hold shows them enlarged.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .gallerySurface(radius: 22)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
    }
    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: Binding<Int?>(get: { tab }, set: { if let index = $0 { select(index) } })) {
                ForEach(tabOrder + [3], id: \.self) { index in
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
            default: SourcesView(model: model)
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
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
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
            if let event = event(for: item) { sheet = .event(event) }
            else { error = "This event changed or was removed. Refresh your agenda." }
        }
    }
    /// The exact occurrence an agenda row shows, rather than another instance of a recurring event.
    func event(for item: AgendaItem) -> EKEvent? {
        let day = Calendar.current.startOfDay(for: item.date)
        let range = DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
        return events(in: range).first {
            "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)" == (item.sourceID ?? item.id)
        }
    }
    /// Deletes an event. A one-time event can be brought back with Undo (as a copy with a new identifier).
    func delete(_ event: EKEvent, span: EKSpan = .thisEvent) {
        guard event.calendar?.allowsContentModifications == true else { error = "This calendar is read-only."; return }
        let snapshot = event.hasRecurrenceRules ? nil : EventSnapshot(event)
        do {
            try store.remove(event, span: span, commit: true)
            let title = event.title ?? "Event"
            if let snapshot {
                undo = UndoAction(message: "Deleted “\(title)”") { [weak self] in
                    guard let self else { return }
                    do { try snapshot.restore(in: self.store); self.scheduleRefresh() }
                    catch { self.error = error.localizedDescription }
                }
            }
            scheduleRefresh()
        } catch { self.error = error.localizedDescription }
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
    /// Moves one occurrence of an event, keeping its length, with Undo.
    func move(_ event: EKEvent, to shifted: Date) {
        let originalStart = event.startDate!, originalEnd = event.endDate!
        guard shifted != originalStart, event.isWritable else { return }
        event.startDate = shifted
        event.endDate = shifted.addingTimeInterval(originalEnd.timeIntervalSince(originalStart))
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let title = event.title ?? "Event"
            undo = UndoAction(message: "Moved “\(title)” to \(shifted.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") { [weak self] in
                guard let self else { return }
                event.startDate = originalStart
                event.endDate = originalEnd
                do { try self.store.save(event, span: .thisEvent, commit: true); self.scheduleRefresh() }
                catch { self.error = error.localizedDescription }
            }
            scheduleRefresh()
        } catch {
            event.startDate = originalStart
            event.endDate = originalEnd
            self.error = error.localizedDescription
        }
    }
    /// Opens the Add to Calendar sheet for an .ics file shared to the app or picked in Settings.
    func importCalendarFile(_ url: URL) {
        guard calendarAccess else {
            error = "Allow LotsOfEvents to use your calendars to add events from a file."
            errorOffersSettings = true
            return
        }
        do { sheet = .importICS(try ICSParser.events(at: url)) }
        catch { self.error = "The file couldn't be read. \(error.localizedDescription)" }
        // Files shared to the app arrive as a copy in an "…Inbox" folder; it isn't needed once read.
        if url.deletingLastPathComponent().lastPathComponent.hasSuffix("Inbox") { try? FileManager.default.removeItem(at: url) }
    }
    /// Changes when one occurrence of an event ends, with Undo.
    func resize(_ event: EKEvent, end: Date) {
        let originalEnd = event.endDate!
        guard end != originalEnd, end > event.startDate, event.isWritable else { return }
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
            undo = UndoAction(message: "“\(event.title ?? "Event")” now ends at \(end.formatted(date: .omitted, time: .shortened))") { [weak self] in
                guard let self else { return }
                event.endDate = originalEnd
                do { try self.store.save(event, span: .thisEvent, commit: true); self.scheduleRefresh() }
                catch { self.error = error.localizedDescription }
            }
            scheduleRefresh()
        } catch {
            event.endDate = originalEnd
            self.error = error.localizedDescription
        }
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

/// A one-time event's details, kept so Undo can recreate it after a delete.
struct EventSnapshot {
    let title: String?
    let location: String?
    let structuredLocation: EKStructuredLocation?
    let notes: String?
    let url: URL?
    let allDay: Bool
    let start: Date
    let end: Date
    let timeZone: TimeZone?
    let availability: EKEventAvailability
    let calendarID: String
    let alarms: [EKAlarm]?
    init(_ event: EKEvent) {
        title = event.title
        location = event.location
        structuredLocation = event.structuredLocation?.copy() as? EKStructuredLocation
        notes = event.notes
        url = event.url
        allDay = event.isAllDay
        start = event.startDate
        end = event.endDate
        timeZone = event.timeZone
        availability = event.availability
        calendarID = event.calendar?.calendarIdentifier ?? ""
        alarms = event.alarms?.compactMap { $0.copy() as? EKAlarm }
    }
    func restore(in store: EKEventStore) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.structuredLocation = structuredLocation
        event.notes = notes
        event.url = url
        event.isAllDay = allDay
        event.timeZone = timeZone
        event.startDate = start
        event.endDate = end
        event.availability = availability
        event.calendar = store.calendar(withIdentifier: calendarID) ?? store.defaultCalendarForNewEvents
        event.alarms = alarms
        try store.save(event, span: .thisEvent, commit: true)
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
        listID = reminder.calendar?.calendarIdentifier ?? ""
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

/// Apple's event view, which already shows invitees, the Accept, Maybe, and Decline buttons for invitations,
/// and Join for video calls, with a bar below for directions (with the drive time) and Duplicate.
struct EventDetailsSheet: View {
    @AppAccent private var accent
    let event: EKEvent
    let onDuplicate: () -> Void
    var body: some View {
        EventDetails(event: event)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if let place = event.location, !place.isEmpty, MeetingLink.url(url: nil, location: place, notes: nil) == nil {
                        Button { directions() } label: {
                            Label("Directions\(TravelAlerts.estimates[event.occurrenceKey].map { " · \(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))" } ?? "")",
                                  systemImage: "car.fill").frame(maxWidth: .infinity)
                        }
                    }
                    Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity) }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered).controlSize(.large).tint(accent)
                .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
                .background(.bar)
            }
    }
    private func directions() {
        let query = event.structuredLocation?.geoLocation.map { "daddr=\($0.coordinate.latitude),\($0.coordinate.longitude)" }
            ?? "daddr=\((event.location ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let url = URL(string: "maps://?\(query)") { UIApplication.shared.open(url) }
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

/// Applies the app's own text size, or leaves the iPhone's setting alone when it's Automatic.
private struct TextSizeModifier: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size { content.dynamicTypeSize(size) } else { content }
    }
}
