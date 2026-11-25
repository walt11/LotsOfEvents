import SwiftUI
import EventKit
import CoreLocation
import MapKit
import Contacts
import UserNotifications
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AppIntents
import WidgetKit

extension EKEvent {
    /// One occurrence of a possibly repeating event.
    var occurrenceKey: String { "\(contactDateID ?? calendarItemIdentifier)-\(startDate.timeIntervalSince1970)" }
}

// MARK: - Rows

/// Opens the event's video call.
struct JoinButton: View {
    let url: URL
    var body: some View {
        Link(destination: url) {
            Label("Join", systemImage: "video.fill").font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(GalleryPalette.success.opacity(0.15), in: Capsule()).foregroundStyle(GalleryPalette.success)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Join \(MeetingLink.service(url)) call")
    }
}

/// Small notes under an event's title: an unanswered invitation, or a clash with another event.
struct EventBadges: View {
    let needsReply: Bool
    let conflict: Bool
    var body: some View {
        if needsReply || conflict {
            HStack(spacing: 6) {
                if needsReply { Label("Needs reply", systemImage: "envelope.badge").foregroundStyle(GalleryPalette.accent) }
                if conflict {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Scheduling overlap")
                        .help("Overlaps another event")
                }
            }.font(.caption2.weight(.medium)).labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Location and travel

enum LocationProvider {
    /// A recent location, or a fresh one within a few seconds; nil without permission.
    @MainActor static func current() async -> CLLocation? {
        if let recent = CLLocationManager().location, recent.timestamp.timeIntervalSinceNow > -1800 { return recent }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                let session = CLServiceSession(authorization: .whenInUse)
                defer { session.invalidate() }
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// "Time to leave" notifications: for events in the next 12 hours that have a place, the drive time from here,
/// and an alert five minutes before it's time to go.
@MainActor enum TravelAlerts {
    static let key = "timeToLeave"
    /// Drive times by event occurrence, for the event details.
    private(set) static var estimates: [String: TimeInterval] = [:]
    /// Recent routes, so frequent refreshes don't request directions again from nearly the same place.
    private static var routes: [String: (travel: TimeInterval, origin: CLLocation, at: Date)] = [:]
    /// Why Time to Leave can't work right now, for Settings.
    static var locationBlocked: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }
    /// Turns on what Time to Leave needs. Returns a message when something is still off.
    static func enable() async -> String? {
        guard await requestPermission() else { return "Allow notifications for LotsOfEvents in system Settings to get Time to Leave alerts." }
        if CLLocationManager().authorizationStatus == .notDetermined { _ = await LocationProvider.current() }
        return locationBlocked ? "Allow location access for LotsOfEvents in system Settings to work out when to leave." : nil
    }
    private static func driveTime(for event: EKEvent, from here: CLLocation, to destination: CLLocation) async -> TimeInterval? {
        if let route = routes[event.occurrenceKey], Date.now.timeIntervalSince(route.at) < 900, route.origin.distance(from: here) < 500 { return route.travel }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile
        request.departureDate = event.startDate.addingTimeInterval(-1800)
        guard let travel = try? await MKDirections(request: request).calculateETA().expectedTravelTime else { return nil }
        routes = routes.filter { Date.now.timeIntervalSince($0.value.at) < 3600 }
        routes[event.occurrenceKey] = (travel, here, .now)
        return travel
    }
    private static var places: [String: CLLocation] = [:]
    static var enabled: Bool { Preferences.defaults.bool(forKey: key) }
    private static var revision = 0
    /// Keep eligible alerts while refreshing estimates; only remove alerts whose events disappeared or were disabled.
    static func obsoleteIDs(pending: [String], eligible: Set<String>, enabled: Bool) -> [String] {
        pending.filter { $0.hasPrefix("leave-") && (!enabled || !eligible.contains($0)) }
    }
    static func update(events: [EKEvent]) async {
        revision += 1
        let current = revision
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("leave-") }
        guard current == revision, !Task.isCancelled else { return }
        let soon = events.filter {
            !$0.isAllDay && $0.startDate > .now && $0.startDate < .now.addingTimeInterval(12 * 3600)
                && ($0.structuredLocation?.geoLocation != nil || !($0.location ?? "").isEmpty)
                && MeetingLink.url(url: nil, location: $0.location, notes: nil) == nil
        }
        let eligible = Set(soon.map { "leave-\($0.occurrenceKey)" })
        center.removePendingNotificationRequests(withIdentifiers: obsoleteIDs(pending: old, eligible: eligible, enabled: enabled))
        guard enabled else { estimates = [:]; return }
        guard !soon.isEmpty, !locationBlocked, let here = await LocationProvider.current(), current == revision, !Task.isCancelled else { return }
        for event in soon.prefix(8) {
            guard current == revision, !Task.isCancelled else { return }
            guard let destination = await place(for: event) else { continue }
            guard current == revision, !Task.isCancelled else { return }
            if destination.distance(from: here) <= 300 {
                center.removePendingNotificationRequests(withIdentifiers: ["leave-\(event.occurrenceKey)"])
                continue
            }
            guard let travel = await driveTime(for: event, from: here, to: destination) else { continue }
            guard current == revision, !Task.isCancelled else { return }
            estimates[event.occurrenceKey] = travel
            // Any preparation time comes before leaving; the planned travel time is replaced by the real drive.
            let leave = event.startDate.addingTimeInterval(-travel - 300 - Double(PlanningPreferences.buffer(event, travel: false) * 60))
            guard leave > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Time to leave for \(event.title ?? "your event")"
            content.body = "About \(Duration.seconds(travel).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) drive to \(event.location ?? "the location"). Starts at \(event.startDate.formatted(date: .omitted, time: .shortened))."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: leave), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "leave-\(event.occurrenceKey)", content: content, trigger: trigger))
        }
    }
    private static func place(for event: EKEvent) async -> CLLocation? {
        if let geo = event.structuredLocation?.geoLocation { return geo }
        guard let address = event.location, !address.isEmpty else { return nil }
        if let cached = places[address] { return cached }
        let found = try? await CLGeocoder().geocodeAddressString(address).first?.location
        if let found { places[address] = found }
        return found
    }
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

// MARK: - Live Activity

/// Keeps one Live Activity for the event that's on now or starts within the hour. iOS only lets the app start
/// it while open, so it appears the next time the app is used before a meeting.
@MainActor enum NextEventActivity {
    static let key = "nextEventActivity"
    static var enabled: Bool { Preferences.defaults.object(forKey: key) as? Bool ?? true }
    static func update(events: [EKEvent]) async {
        #if !targetEnvironment(macCatalyst)
        let now = Date.now
        let next = events.filter { !$0.isAllDay && $0.endDate > now && $0.startDate < now.addingTimeInterval(3600) }
            .min { $0.startDate < $1.startDate }
        let wanted = enabled && ActivityAuthorizationInfo().areActivitiesEnabled ? next : nil
        for activity in Activity<NextEventAttributes>.activities where activity.attributes.eventID != wanted?.occurrenceKey {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let event = wanted else { return }
        let state = NextEventAttributes.ContentState(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                                                     location: event.location, colorRGB: rgb(event.calendar?.cgColor), joinURL: MeetingLink.url(for: event))
        // Going stale at the start redraws the countdown so it switches to the time left, without the app running.
        let content = ActivityContent(state: state, staleDate: event.startDate > now ? event.startDate : event.endDate)
        var updated = false
        for activity in Activity<NextEventAttributes>.activities where activity.attributes.eventID == event.occurrenceKey {
            await activity.update(content)
            updated = true
        }
        if !updated { _ = try? Activity.request(attributes: NextEventAttributes(eventID: event.occurrenceKey), content: content) }
        #endif
    }
    private static func rgb(_ color: CGColor?) -> Int {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return 0x007AFF }
        return parts.prefix(3).reduce(0) { $0 << 8 | Int(max(0, min(1, $1)) * 255) }
    }
}

// MARK: - Calendar sets

/// The filter menu on Calendar and Agenda: switch calendar sets, choose calendars, and save the selection as a set.
struct CalendarSetsMenu: View {
    @ObservedObject var model: AgendaModel
    @State private var naming = false
    @State private var name = ""
    @State private var managing = false
    var body: some View {
        let sets = CalendarSet.saved
        let active = CalendarSet.activeID
        Menu {
            Picker("Calendar set", selection: Binding(get: { active }, set: { id in apply(sets.first { $0.id == id }) })) {
                Label("All Calendars", systemImage: "square.stack").tag(UUID?.none)
                ForEach(sets) { set in Text(set.name).tag(Optional(set.id)) }
            }
            Divider()
            Button("Choose Calendars…", systemImage: "calendar") { model.sheet = .sources(reminders: false) }
            Button("Save Current Calendars as Set…", systemImage: "plus") { name = ""; naming = true }
            if !sets.isEmpty { Button("Manage Sets…", systemImage: "slider.horizontal.3") { managing = true } }
        } label: {
            // The same filter symbol as the Reminders tab; filled while a set narrows what's shown.
            Label("Show", systemImage: active == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Calendars shown")
        .accessibilityValue(sets.first { $0.id == active }?.name ?? "All calendars")
        .alert("New Calendar Set", isPresented: $naming) {
            TextField("Name, like Work", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let set = CalendarSet.current(named: trimmed)
                CalendarSet.saved.append(set)
                CalendarSet.activeID = set.id
                model.objectWillChange.send()
            }
        } message: { Text("Saves the calendars and reminder lists shown now. Choose calendars in Settings first.") }
        .sheet(isPresented: $managing) { NavigationStack { CalendarSetsView(model: model) } }
    }
    private func apply(_ set: CalendarSet?) {
        CalendarSet.apply(set)
        model.objectWillChange.send()
        model.scheduleRefresh()
        WidgetReloader.schedule()
    }
}

/// Renames, reorders, and deletes calendar sets, and explains the Focus filter.
struct CalendarSetsView: View {
    @ObservedObject var model: AgendaModel
    @State private var sets = CalendarSet.saved
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                ForEach($sets) { $set in
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $set.name).font(.body.weight(.medium))
                        Text(summary(set)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { sets.remove(atOffsets: $0) }
                .onMove { sets.move(fromOffsets: $0, toOffset: $1) }
                if sets.isEmpty { Text("No sets yet. In Calendar or Agenda, open the filter menu and choose Save Current Calendars as Set.").foregroundStyle(.secondary) }
            } footer: {
                Text("A set remembers which calendars and reminder lists are shown. To switch sets with a Focus, go to Settings → Focus, choose a Focus, then Add Filter and choose LotsOfEvents.")
            }
        }
        .navigationTitle("Calendar Sets").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onChange(of: sets) { _, value in
            CalendarSet.saved = value.map { var set = $0; set.name = set.name.isEmpty ? "Untitled" : set.name; return set }
            if let active = CalendarSet.activeID, !value.contains(where: { $0.id == active }) { CalendarSet.activeID = nil }
            model.objectWillChange.send()
        }
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
    private func summary(_ set: CalendarSet) -> String {
        let calendars = model.calendars.filter { !set.hiddenCalendars.contains($0.calendarIdentifier) }.count
        let lists = model.lists.filter { !set.hiddenLists.contains($0.calendarIdentifier) }.count
        return "\(calendars) calendars · \(lists) reminder lists"
    }
}

struct CalendarSetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar Set"
    static let defaultQuery = CalendarSetQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CalendarSetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CalendarSetEntity] {
        CalendarSet.saved.filter { identifiers.contains($0.id.uuidString) }.map { CalendarSetEntity(id: $0.id.uuidString, name: $0.name) }
    }
    func suggestedEntities() async throws -> [CalendarSetEntity] {
        CalendarSet.saved.map { CalendarSetEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

/// A Focus filter: while a Focus is on, show one calendar set; when it ends, iOS runs this again with no set,
/// which puts back what was showing before.
struct CalendarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Show a Calendar Set"
    static let description: IntentDescription? = "Shows only the calendars and reminder lists in a set while this Focus is on."
    @Parameter(title: "Calendar Set") var calendarSet: CalendarSetEntity?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(calendarSet?.name ?? "All Calendars")")
    }
    func perform() async throws -> some IntentResult {
        if let set = CalendarSet.saved.first(where: { $0.id.uuidString == calendarSet?.id }) { CalendarSet.focusBegan(set) }
        else { CalendarSet.focusEnded() }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Reminder notifications

@MainActor enum ReminderNotifications {
    static let key = "appReminderNotifications"
    static let statusKey = "appReminderNotificationStatus"
    static let pendingOpenKey = "notificationReminderID"
    /// Preserve existing LotsOfEvents alerts unless the user explicitly opts out.
    static let includeOwnAlarmsKey = "appReminderNotificationsIncludeAlarms"
    static let offeredKey = "appReminderNotificationsOffered"
    static var enabled: Bool { Preferences.defaults.object(forKey: key) as? Bool ?? true }
    static var includeOwnAlarms: Bool { includesOwnAlarms(in: Preferences.defaults) }
    static func includesOwnAlarms(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: includeOwnAlarmsKey) as? Bool ?? true
    }
    static func snoozeKey(_ id: String) -> String { "reminderSnooze.\(id)" }
    private static var revision = 0
    private static var lastPlan: (fingerprint: Int, at: Date)?

    nonisolated static let completeAction = "reminder.complete"
    nonisolated static let snoozeAction = "reminder.snooze"
    static let category = UNNotificationCategory(identifier: "reminder", actions: [
        UNNotificationAction(identifier: completeAction, title: "Complete", options: []),
        UNNotificationAction(identifier: snoozeAction, title: "Remind in 1 Hour", options: [])
    ], intentIdentifiers: [])

    /// True once there's a reason to ask: a dated task to alert for and no answer yet, and only the first time.
    static func shouldOffer(reminders: [EKReminder]) async -> Bool {
        guard enabled, !Preferences.defaults.bool(forKey: offeredKey), reminders.contains(where: { !$0.isCompleted && ReminderDates.due($0) != nil }) else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }
    /// The answer to the app's own explanation; "Not Now" leaves the system prompt unused for later.
    static func answerOffer(allow: Bool) async {
        Preferences.defaults.set(true, forKey: offeredKey)
        guard allow else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    /// Runs a notification's Complete or snooze button; the app may be in the background with no window.
    static func perform(action: String, reminderID: String) async {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder, reminder.isWritable, !reminder.isCompleted else { return }
        if action == completeAction { reminder.isCompleted = true }
        else { ReminderSchedule.apply(to: reminder, due: Date.now.addingTimeInterval(3600), timed: true, repeatRule: .keep, alert: .keep) }
        guard (try? store.save(reminder, commit: true)) != nil else { return }
        // Persist an explicit snooze independently of default alarm preferences, including across launches.
        let key = snoozeKey(reminderID)
        if action == snoozeAction, let due = ReminderDates.due(reminder) {
            Preferences.defaults.set(due.timeIntervalSince1970, forKey: key)
        } else { Preferences.defaults.removeObject(forKey: key) }
        // Reconcile all tasks before finishing the background action; no active app window is required.
        lastPlan = nil
        let reminders = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        await update(reminders: reminders)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Explicit alarms win. An item without alarms uses the app's due-time defaults.
    static func dates(for reminder: EKReminder, now: Date, option: ReminderAlertOption = AlertDefaults.reminder,
                      dateOnly: Bool = AlertDefaults.dateOnlyEnabled, minute: Int = AlertDefaults.dateOnlyMinute,
                      includeOwnAlarms: Bool = includeOwnAlarms, calendar: Calendar = .current) -> [Date] {
        guard !reminder.isCompleted else { return [] }
        let due = ReminderDates.due(reminder)
        if let timestamp = Preferences.defaults.object(forKey: snoozeKey(reminder.calendarItemIdentifier)) as? Double {
            let snoozed = Date(timeIntervalSince1970: timestamp)
            if let due, abs(due.timeIntervalSince(snoozed)) < 1, snoozed > now { return [snoozed] }
        }
        let alarms = reminder.alarms ?? []
        let dates: [Date]
        if !alarms.isEmpty {
            guard includeOwnAlarms else { return [] }
            dates = alarms.compactMap { alarm in
                // Location alerts stay with Apple's Reminders; don't turn them into time alerts.
                guard alarm.structuredLocation == nil else { return nil }
                return alarm.absoluteDate ?? due?.addingTimeInterval(alarm.relativeOffset)
            }
        } else if let due {
            dates = [AlertDefaults.reminderAlarmDate(due: due, timed: reminder.dueDateComponents?.hour != nil,
                         option: option, dateOnly: dateOnly, dateOnlyMinute: minute, calendar: calendar)].compactMap { $0 }
        } else { dates = [] }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }

    private static var pendingUpdate: Task<Void, Never>?
    static func update(reminders: [EKReminder]) async {
        // Most refreshes change nothing about alerts. The time limit lets later alerts move into the system's 64 slots.
        var hasher = Hasher()
        hasher.combine(enabled); hasher.combine(includeOwnAlarms); hasher.combine(AlertDefaults.reminder.rawValue)
        hasher.combine(AlertDefaults.dateOnlyEnabled); hasher.combine(AlertDefaults.dateOnlyMinute)
        for reminder in reminders.sorted(by: { $0.calendarItemIdentifier < $1.calendarItemIdentifier }) {
            hasher.combine(reminder.calendarItemIdentifier); hasher.combine(reminder.isCompleted); hasher.combine(reminder.title)
            hasher.combine(reminder.calendar?.calendarIdentifier); hasher.combine(ReminderDates.due(reminder)); hasher.combine(reminder.alarms?.count)
            hasher.combine(reminder.lastModifiedDate)
        }
        hasher.combine(Preferences.defaults.stringArray(forKey: "hiddenReminderLists"))
        hasher.combine(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue)
        let fingerprint = hasher.finalize()
        if let lastPlan, lastPlan.fingerprint == fingerprint, Date.now.timeIntervalSince(lastPlan.at) < 900 { return }
        lastPlan = (fingerprint, .now)
        revision += 1
        let current = revision
        let previous = pendingUpdate
        previous?.cancel()
        let next = Task { @MainActor in
            // Finish any in-flight add before reconciling; otherwise a stale alert can be re-added after removal.
            await previous?.value
            guard current == revision else { return }
            await reconcile(reminders: reminders, current: current)
        }
        pendingUpdate = next
        await next.value
    }
    private static func reconcile(reminders: [EKReminder], current: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard current == revision else { return }
        let own = pending.filter { $0.identifier.hasPrefix("reminder-") }
        let permitted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard enabled && permitted else {
            center.removePendingNotificationRequests(withIdentifiers: own.map(\.identifier))
            let delivered = await center.deliveredNotifications()
            guard current == revision else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix("reminder-") })
            Preferences.defaults.set("", forKey: statusKey)
            return
        }
        var settings = await center.notificationSettings()
        // The prompt comes from the app's own explanation or a Settings toggle, never from a background refresh.
        if settings.authorizationStatus == .notDetermined {
            Preferences.defaults.set("", forKey: statusKey)
            return
        }
        settings = await center.notificationSettings()
        guard current == revision else { return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            center.removePendingNotificationRequests(withIdentifiers: own.map(\.identifier))
            Preferences.defaults.set("Allow notifications for LotsOfEvents in system Settings to receive reminder alerts.", forKey: statusKey)
            return
        }
        let now = Date.now
        let active = reminders.filter { !$0.isCompleted && $0.calendar.map { Preferences.selected($0.calendarIdentifier, reminders: true) } == true }
        // Leave eight notification slots for time-to-leave alerts, and preserve any other app requests.
        let reserveContactSlots = ContactDates.enabled && (Preferences.defaults.object(forKey: PlanningPreferences.contactAlerts) as? Int ?? -1) >= 0 ? 12 : 0
        let capacity = max(0, 56 - reserveContactSlots - pending.filter { !$0.identifier.hasPrefix("reminder-") && !$0.identifier.hasPrefix("leave-") && !$0.identifier.hasPrefix("contact-occasion-") }.count)
        let planned = active.flatMap { reminder in dates(for: reminder, now: now).map { (reminder, $0) } }
            .sorted { $0.1 < $1.1 }.prefix(capacity)
        let ids = Set(planned.map { "reminder-\($0.0.calendarItemIdentifier)-\(Int($0.1.timeIntervalSince1970))" })
        center.removePendingNotificationRequests(withIdentifiers: own.map(\.identifier).filter { !ids.contains($0) })
        let activeIDs = Set(active.map(\.calendarItemIdentifier))
        let delivered = await center.deliveredNotifications()
        guard current == revision else { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.compactMap { notification in
            guard notification.request.identifier.hasPrefix("reminder-"),
                  let id = notification.request.content.userInfo["reminderID"] as? String,
                  !activeIDs.contains(id) else { return nil }
            return notification.request.identifier
        })
        var failed = false
        for (reminder, date) in planned {
            guard current == revision else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title ?? "Reminder"
            content.body = reminder.calendar?.title ?? ""
            content.sound = .default
            content.categoryIdentifier = "reminder"
            content.threadIdentifier = "reminder-list-\(reminder.calendar?.calendarIdentifier ?? "")"
            content.userInfo = ["reminderID": reminder.calendarItemIdentifier]
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.timeZone = .current
            let request = UNNotificationRequest(identifier: "reminder-\(reminder.calendarItemIdentifier)-\(Int(date.timeIntervalSince1970))", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) } catch { failed = true }
        }
        guard current == revision else { return }
        Preferences.defaults.set(failed ? "Some reminder alerts could not be scheduled. Reopen the app to retry." : "", forKey: statusKey)
    }
}

@MainActor final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationDelegate()
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler([.banner, .list, .sound]) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        // Copy only values across isolation boundaries. UIKit's completion performs
        // snapshot/state restoration and must run on the main thread, even when
        // the notification (for example a travel alert) has no routing payload.
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let contactID = info["contactDateID"] as? String
        let timestamp = info["contactDateTimestamp"] as? Double
        let reminderID = info["reminderID"] as? String
        Self.receive(action: action, contactID: contactID, timestamp: timestamp, reminderID: reminderID, completionHandler: completionHandler)
    }
    nonisolated static func receive(action: String, contactID: String?, timestamp: Double?, reminderID: String?,
        completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            await Self.handleResponse(action: action, contactID: contactID, timestamp: timestamp, reminderID: reminderID)
        }
    }
    static func handleResponse(action: String, contactID: String?, timestamp: Double?, reminderID: String?) async {
        if action == UNNotificationDefaultActionIdentifier, let id = contactID, let date = timestamp {
            Preferences.defaults.set(id, forKey: "pendingContactDateID")
            Preferences.defaults.set(date, forKey: "pendingContactDateTimestamp")
            ReminderNotificationRoute.shared.contactDateID = id
            return
        }
        guard let id = reminderID else { return }
        if action == ReminderNotifications.completeAction || action == ReminderNotifications.snoozeAction {
            await ReminderNotifications.perform(action: action, reminderID: id)
            return
        }
        guard action == UNNotificationDefaultActionIdentifier else { return }
        ReminderNotificationRoute.shared.open(id)
    }
}


/// Retains notification taps across cold launch and inactive-to-active scene transitions.
@MainActor final class ReminderNotificationRoute: ObservableObject {
    static let shared = ReminderNotificationRoute()
    @Published var contactDateID: String? = Preferences.defaults.string(forKey: "pendingContactDateID")
    @Published private(set) var reminderID: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = Preferences.defaults) {
        self.defaults = defaults
        reminderID = defaults.string(forKey: ReminderNotifications.pendingOpenKey)
    }
    func open(_ id: String) {
        defaults.set(id, forKey: ReminderNotifications.pendingOpenKey)
        reminderID = id
    }
    func handled(_ id: String) {
        guard reminderID == id else { return }
        defaults.removeObject(forKey: ReminderNotifications.pendingOpenKey)
        reminderID = nil
    }
}
