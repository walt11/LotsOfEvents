import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

@main
struct LotsOfEventsApp: App {
    init() {
        AccentStore.migrateFromAppDefaults()
        // Adopt the redesign once; retain custom artwork and every per-widget override.
        if !Preferences.defaults.bool(forKey: "galleryAppearanceInstalled") {
            let previous = Preferences.defaults.string(forKey: "widgetTheme")
            if previous != "custom" {
                Preferences.defaults.set(previous, forKey: "previousWidgetTheme")
                Preferences.defaults.set("gallery", forKey: "widgetTheme")
            }
            Preferences.defaults.set(true, forKey: "galleryAppearanceInstalled")
            WidgetCenter.shared.reloadAllTimelines()
        }
        if !Preferences.defaults.bool(forKey: "charcoalDefaultInstalled") {
            Preferences.defaults.set(Preferences.defaults.string(forKey: "widgetTheme"), forKey: "themeBeforeCharcoal")
            Preferences.defaults.set("charcoal", forKey: "widgetTheme")
            Preferences.defaults.set(true, forKey: "charcoalDefaultInstalled")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    var body: some Scene { WindowGroup { MainView() } }
}

@MainActor
final class AgendaModel: ObservableObject {
    let store = EKEventStore()
    @Published var calendars: [EKCalendar] = []
    @Published var lists: [EKCalendar] = []
    @Published var error: String?
    /// True when `error` is a permissions problem, so the alert offers Settings.
    @Published var errorOffersSettings = false
    @Published var loading = false
    @Published var reminders: [EKReminder] = []
    /// Completed reminders are fetched only while a view shows them; accounts can have years of history.
    @Published var includeCompleted = false { didSet { if includeCompleted != oldValue { scheduleRefresh() } } }
    @Published var completedLoaded = false
    @Published var undo: UndoAction?
    @Published var generation = 0
    @Published var agendaReturnToToday = 0
    @Published var calendarReturnToToday = 0
    var calendarCreationDate = Date.now.roundedUpToHalfHour()
    var activeReminderList: String?
    @Published var sheet: AppSheet?
    private var revision = 0
    private var pendingRefresh: Task<Void, Never>?
    /// Coalesces bursts of triggers (store notifications, saves, sheet dismissals) into one fetch.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
    func refresh() async {
        revision += 1
        let current = revision
        loading = true
        calendars = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? store.calendars(for: .event) : []
        lists = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? store.calendars(for: .reminder) : []
        if !calendars.isEmpty { Preferences.migrateCalendars(available: calendars.map(\.calendarIdentifier)) }
        let wantsCompleted = includeCompleted
        var fetched: [EKReminder] = []
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            fetched = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
            if wantsCompleted {
                fetched += await store.reminders(matching: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil))
            }
        }
        guard current == revision else { return }
        reminders = fetched
        completedLoaded = wantsCompleted
        generation += 1
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }
    func request(_ type: EKEntityType) async {
        do {
            let granted = try await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
            if !granted {
                errorOffersSettings = true
                error = "Access is off. You can enable it in Settings → Apps → LotsOfEvents."
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}

/// A short-lived offer to reverse the last reminder change.
struct UndoAction: Identifiable {
    let id = UUID()
    let message: String
    let perform: @MainActor () -> Void
}

struct AgendaView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @StateObject private var agenda = ContinuousAgenda()
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                    Section {
                        Label("Bring your calendars together", systemImage: "calendar.badge.checkmark").font(.headline)
                        Text("Connect Apple Calendar to see events from accounts synced with your iPhone.").foregroundStyle(.secondary)
                        Button("Connect calendars") { Task { await model.request(.event) } }
                    }
                }
                ForEach(ContinuousAgenda.sections(agenda.days, today: .now)) { section in
                    switch section {
                    case .day(let day):
                        Section {
                            if day.items.isEmpty {
                                Text("Nothing scheduled").font(.caption).foregroundStyle(GalleryPalette.muted).listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            }
                            ForEach(day.items) { item in itemRow(item) }
                        } header: { Text(dayTitle(day.date)).font(.system(.caption, design: .monospaced)).foregroundStyle(GalleryPalette.muted) }
                            .id(Calendar.current.isDateInToday(day.date) ? "agenda-today" : day.date.description)
                    case .empty(let start, let end):
                        Section {
                            Label(start == end ? "Nothing scheduled \(start.formatted(.dateTime.weekday(.wide).month().day()))" : "Nothing scheduled \((start..<end).formatted(.interval.month(.abbreviated).day()))", systemImage: "moon.zzz")
                                .font(.caption).foregroundStyle(GalleryPalette.muted).listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }
                if !agenda.days.isEmpty && (model.calendarAccess || model.reminderAccess) {
                    // Loads the next 30 days when this row scrolls into view.
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                        .task(id: agenda.days.last?.id) { await agenda.loadMore(store: model.store) }
                }
            }
            .task(id: model.generation) { await agenda.refresh(store: model.store) }
            .listSectionSpacing(10)
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Agenda")
            .galleryTitle("Agenda")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Today") { withAnimation { proxy.scrollTo("agenda-today", anchor: .top) } } }
            }
            .tint(accent)
            .refreshable { await model.refresh() }
            .onChange(of: model.agendaReturnToToday) { _, _ in
                withAnimation { proxy.scrollTo("agenda-today", anchor: .top) }
                model.scheduleRefresh()
            }
            }
        }
    }
    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today · \(date.formatted(.dateTime.weekday(.wide).month().day()))" }
        return calendar.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide).month().day())
    }
    private func itemRow(_ item: AgendaItem) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 4)
            if item.reminder {
                Button { if let reminder = model.reminder(withID: item.id) { model.toggle(reminder) } } label: {
                    Image(systemName: "circle").font(.title3).foregroundStyle(item.color).frame(width: 28, height: 36)
                }.buttonStyle(.borderless).accessibilityLabel("Complete \(item.title)")
            }
            Button { model.open(item) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        if let detail = item.agendaDetail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(item.timeLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .galleryRow()
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        .swipeActions(edge: .trailing) {
            if item.reminder, let reminder = model.reminder(withID: item.id) { SnoozeButtons(model: model, reminder: reminder) }
        }
    }
}

struct EventEditor: UIViewControllerRepresentable {
    @AppAccent private var accent
    let store: EKEventStore
    var startDate: Date = .now
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.view.tintColor = UIColor(accent)
        let event = EKEvent(eventStore: store)
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, @MainActor EKEventEditViewDelegate {
        let parent: EventEditor
        init(parent: EventEditor) { self.parent = parent }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { parent.dismiss() }
    }
}
