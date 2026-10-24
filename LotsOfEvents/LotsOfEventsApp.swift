import SwiftUI
import EventKit
import EventKitUI
import WidgetKit

@main
struct LotsOfEventsApp: App {
    var body: some Scene { WindowGroup { MainView() } }
}

@MainActor
final class AgendaModel: ObservableObject {
    let store = EKEventStore()
    @Published var items: [AgendaItem] = []
    @Published var calendars: [EKCalendar] = []
    @Published var lists: [EKCalendar] = []
    @Published var error: String?
    @Published var loading = false
    @Published var reminders: [EKReminder] = []
    @Published var generation = 0
    @Published var sheet: AppSheet?
    private var revision = 0
    func refresh() async {
        revision += 1
        let current = revision
        loading = true
        calendars = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? store.calendars(for: .event) : []
        lists = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? store.calendars(for: .reminder) : []
        let result = await AgendaQuery.load(store: store)
        let fetched: [EKReminder]
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            fetched = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: store.predicateForReminders(in: nil)) {
                    continuation.resume(returning: $0 ?? [])
                }
            }
        } else { fetched = [] }
        guard current == revision else { return }
        items = result
        reminders = fetched
        generation += 1
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }
    func request(_ type: EKEntityType) async {
        do {
            let granted = try await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
            if !granted { error = "Access is off. You can enable it in Settings → Apps → Lots of Events." }
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}

struct AgendaView: View {
    @ObservedObject var model: AgendaModel
    private var dates: [Date] { Array(Set(model.items.map { Calendar.current.startOfDay(for: $0.date) })).sorted() }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                            .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                        Text("A little room for what’s next.").font(.title2.weight(.semibold))
                        Text("Today + the next \(Preferences.days - 1) days · calendars & reminders")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                    Section {
                        Label("Bring your calendars together", systemImage: "calendar.badge.checkmark").font(.headline)
                        Text("Connect Apple Calendar to see events from accounts synced with your iPhone.").foregroundStyle(.secondary)
                        Button("Connect calendars") { Task { await model.request(.event) } }
                    }
                }
                if model.loading && model.items.isEmpty { ProgressView("Loading your agenda…") }
                else if model.items.isEmpty {
                    ContentUnavailableView("A clear horizon", systemImage: "sun.horizon", description: Text("No items in this date range. Choose calendars and reminder lists, or add an event."))
                }
                ForEach(dates, id: \.self) { date in
                    Section {
                        ForEach(model.items.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }) { item in
                            Button { model.open(item) } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 4)
                                Image(systemName: item.reminder ? "circle.dashed" : "calendar").foregroundStyle(item.color)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.body.weight(.medium))
                                    Text(item.source).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.timeLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    } header: {
                        Text(Calendar.current.isDateInToday(date) ? "Today" : Calendar.current.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide).month().day()))
                    }
                }
            }
            .navigationTitle("Upcoming")
            .tint(.teal)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Sources", systemImage: "slider.horizontal.3") { model.sheet = .sources } }
                ToolbarItem(placement: .topBarTrailing) { Button("New event", systemImage: "plus") { model.sheet = .newEvent(.now) } }
            }
            .refreshable { await model.refresh() }

        }
    }
}

struct SourcesView: View {
    @ObservedObject var model: AgendaModel
    @Environment(\.dismiss) private var dismiss
    @State private var days = Preferences.days
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("widgetTheme", store: Preferences.defaults) private var themeID = AgendaTheme.selected.rawValue
    var body: some View {
        NavigationStack {
            Form {
                Section("Looking ahead") {
                    Stepper("\(days) days, including today", value: $days, in: 2...14)
                        .onChange(of: days) { _, value in Preferences.days = value; Preferences.defaults.set(0, forKey: "page"); Task { await model.refresh() } }
                }
                Section {
                    ForEach(AgendaTheme.allCases) { theme in
                        Button {
                            themeID = theme.rawValue
                            WidgetCenter.shared.reloadAllTimelines()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("TODAY").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.accent(colorScheme))
                                    HStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1).fill(theme.accent(colorScheme)).frame(width: 3, height: 12)
                                        RoundedRectangle(cornerRadius: 2).fill(theme.text(colorScheme).opacity(0.7)).frame(width: 28, height: 3)
                                    }
                                }
                                .padding(8).frame(width: 64, height: 45)
                                .background(theme.background(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                                Text(theme.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: themeID == theme.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(themeID == theme.rawValue ? theme.accent(colorScheme) : Color.secondary)
                            }
                        }
                        .accessibilityLabel(theme.title)
                        .accessibilityValue(themeID == theme.rawValue ? "Selected" : "Not selected")
                    }
                } header: { Text("Widget theme") } footer: {
                    Text("Seven background palettes with your original calendar colors. Black stays black in every appearance; the other themes adapt to light and dark. Your selection applies to all agenda widgets.")
                }
                Section("Calendars") {
                    if model.calendars.isEmpty { Button("Allow calendar access") { Task { await model.request(.event) } } }
                    ForEach(model.calendars, id: \.calendarIdentifier) { source in sourceToggle(source, reminders: false) }
                }
                Section {
                    if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
                        Button("Connect Apple Reminders") { Task { await model.request(.reminder) } }
                    }
                    ForEach(model.lists, id: \.calendarIdentifier) { source in sourceToggle(source, reminders: true) }
                } header: { Text("Reminder lists") } footer: {
                    Text("Select the lists to include. Only incomplete reminders due in the displayed date range appear. Undated and earlier overdue reminders are excluded.")
                }
                Section("Your Home Screen widget") {
                    Text("Touch and hold your Home Screen, choose Edit → Add Widget, then search for Lots of Events. Use the arrows to page through your agenda and + to create an event.")
                    Text("The widget uses these same selections. iOS controls when it refreshes.").foregroundStyle(.secondary)
                }
            }.navigationTitle("Your agenda").toolbar { Button("Done") { dismiss() } }.tint(.teal)
        }
    }
    private func sourceToggle(_ source: EKCalendar, reminders: Bool) -> some View {
        Toggle(isOn: Binding(get: { Preferences.selected(source.calendarIdentifier, reminders: reminders) }, set: {
            Preferences.setSelected(source.calendarIdentifier, enabled: $0, reminders: reminders, available: reminders ? model.lists : model.calendars)
            Task { await model.refresh() }
        })) {
            HStack {
                Circle().fill(Color(cgColor: source.cgColor)).frame(width: 9, height: 9)
                VStack(alignment: .leading) { Text(source.title); Text(source.source.title).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct EventEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    var startDate: Date = .now
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        let event = EKEvent(eventStore: store)
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let parent: EventEditor
        init(parent: EventEditor) { self.parent = parent }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { parent.dismiss() }
    }
}
