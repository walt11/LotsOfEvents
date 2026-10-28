import SwiftUI
import EventKit
import WeatherKit
import CoreLocation
import MapKit
import Contacts
import UserNotifications
import ActivityKit
import AppIntents
import WidgetKit

extension EKEvent {
    /// One occurrence of a possibly repeating event.
    var occurrenceKey: String { "\(calendarItemIdentifier)-\(startDate.timeIntervalSince1970)" }
}

// MARK: - Rows

/// Opens the event's video call.
struct JoinButton: View {
    let url: URL
    var body: some View {
        Link(destination: url) {
            Label("Join", systemImage: "video.fill").font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
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
                if needsReply { Label("Needs reply", systemImage: "envelope.badge").foregroundStyle(.blue) }
                if conflict { Label("Overlaps", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }.font(.caption2.weight(.medium)).labelStyle(.titleAndIcon)
        }
    }
}

/// Adds the age to a birthday ("Sam's Birthday · 34") from the contact's birth year, when allowed.
@MainActor enum BirthdayAges {
    static let key = "birthdayAges"
    private static var years: [String: Int] = [:]
    static var allowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return Preferences.defaults.bool(forKey: key) && (status == .authorized || status == .limited)
    }
    static func title(for event: EKEvent) -> String {
        let title = event.title ?? "Birthday"
        guard allowed, let id = event.birthdayContactIdentifier else { return title }
        let year: Int
        if let cached = years[id] { year = cached } else {
            let keys = [CNContactBirthdayKey as CNKeyDescriptor]
            year = (try? CNContactStore().unifiedContact(withIdentifier: id, keysToFetch: keys))?.birthday?.year ?? 0
            years[id] = year
        }
        let age = Calendar.current.component(.year, from: event.startDate) - year
        return year > 0 && age > 0 ? "\(title) · \(age)" : title
    }
}

// MARK: - Location, weather, and travel

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

/// Daily forecasts for the timeline's day headers, from Apple Weather. Off until turned on in Settings,
/// since it needs the user's location.
@MainActor final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()
    static let key = "showWeather"
    struct DayForecast: Equatable {
        let symbol: String
        let high: Measurement<UnitTemperature>
        let low: Measurement<UnitTemperature>
    }
    @Published private(set) var days: [Date: DayForecast] = [:]
    @Published private(set) var attribution: (mark: URL, legal: URL)?
    /// Why there's no forecast, shown in Settings, since the calendar just leaves it out.
    @Published private(set) var problem: String?
    private var fetched: Date?
    var enabled: Bool { Preferences.defaults.bool(forKey: Self.key) }
    func forecast(for day: Date) -> DayForecast? { enabled ? days[Calendar.current.startOfDay(for: day)] : nil }
    func refresh(force: Bool = false) async {
        guard enabled else { days = [:]; return }
        if !force, let fetched, Date.now.timeIntervalSince(fetched) < 3 * 3600 { return }
        guard let location = await LocationProvider.current() else {
            problem = CLLocationManager().authorizationStatus == .denied
                ? "Location access is off. Turn it on in Settings → Apps → LotsOfEvents → Location."
                : "Couldn't find your location. Try again later."
            return
        }
        do {
            let forecast = try await WeatherService.shared.weather(for: location, including: .daily)
            days = Dictionary(forecast.forecast.map {
                (Calendar.current.startOfDay(for: $0.date), DayForecast(symbol: $0.symbolName, high: $0.highTemperature, low: $0.lowTemperature))
            }, uniquingKeysWith: { first, _ in first })
            fetched = .now
            problem = nil
            if attribution == nil, let info = try? await WeatherService.shared.attribution {
                attribution = (info.combinedMarkLightURL, info.legalPageURL)
            }
        } catch {
            // Weather is extra; without it the headers simply show the dates.
            // A sign-in failure means WeatherKit isn't switched on for the app in Apple's developer account yet.
            problem = (error as NSError).domain.contains("JWTAuthenticator")
                ? "Apple Weather turned down this app. WeatherKit needs to be enabled for it in the Apple Developer account (App ID → App Services)."
                : "Apple Weather didn't respond. Try again later."
        }
    }
}

/// Today's conditions with the high and low, for the Today header.
struct WeatherSummary: View {
    let forecast: WeatherStore.DayForecast
    var body: some View {
        let style = Measurement<UnitTemperature>.FormatStyle(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
        HStack(spacing: 6) {
            Image(systemName: forecast.symbol).symbolRenderingMode(.multicolor).font(.title2)
            VStack(alignment: .leading, spacing: 0) {
                Text(forecast.high.formatted(style)).font(.headline)
                Text(forecast.low.formatted(style)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("High \(forecast.high.formatted(style)), low \(forecast.low.formatted(style))")
    }
}

struct WeatherBadge: View {
    let forecast: WeatherStore.DayForecast
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: forecast.symbol).symbolRenderingMode(.multicolor)
            if !compact { Text(forecast.high.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))) }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("High \(forecast.high.formatted(.measurement(width: .wide, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))))")
    }
}

/// "Time to leave" notifications: for events in the next 12 hours that have a place, the drive time from here,
/// and an alert five minutes before it's time to go.
@MainActor enum TravelAlerts {
    static let key = "timeToLeave"
    /// Drive times by event occurrence, for the event details.
    private(set) static var estimates: [String: TimeInterval] = [:]
    private static var places: [String: CLLocation] = [:]
    static var enabled: Bool { Preferences.defaults.bool(forKey: key) }
    static func update(events: [EKEvent]) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("leave-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard enabled else { estimates = [:]; return }
        let soon = events.filter {
            !$0.isAllDay && $0.startDate > .now && $0.startDate < .now.addingTimeInterval(12 * 3600)
                && ($0.structuredLocation?.geoLocation != nil || !($0.location ?? "").isEmpty)
                && MeetingLink.url(url: nil, location: $0.location, notes: nil) == nil
        }
        guard !soon.isEmpty, let here = await LocationProvider.current() else { return }
        for event in soon.prefix(8) {
            guard let destination = await place(for: event), destination.distance(from: here) > 300 else { continue }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
            request.transportType = .automobile
            request.departureDate = event.startDate.addingTimeInterval(-1800)
            guard let travel = try? await MKDirections(request: request).calculateETA().expectedTravelTime else { continue }
            estimates[event.occurrenceKey] = travel
            let leave = event.startDate.addingTimeInterval(-travel - 300)
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
        let now = Date.now
        let next = events.filter { !$0.isAllDay && $0.endDate > now && $0.startDate < now.addingTimeInterval(3600) }
            .min { $0.startDate < $1.startDate }
        let wanted = enabled && ActivityAuthorizationInfo().areActivitiesEnabled ? next : nil
        for activity in Activity<NextEventAttributes>.activities where activity.attributes.eventID != wanted?.occurrenceKey {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let event = wanted else { return }
        let state = NextEventAttributes.ContentState(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                                                     location: event.location, colorRGB: rgb(event.calendar.cgColor), joinURL: MeetingLink.url(for: event))
        let content = ActivityContent(state: state, staleDate: event.endDate)
        var updated = false
        for activity in Activity<NextEventAttributes>.activities where activity.attributes.eventID == event.occurrenceKey {
            await activity.update(content)
            updated = true
        }
        if !updated { _ = try? Activity.request(attributes: NextEventAttributes(eventID: event.occurrenceKey), content: content) }
    }
    private static func rgb(_ color: CGColor?) -> Int {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return 0x007AFF }
        return parts.prefix(3).reduce(0) { $0 << 8 | Int(max(0, min(1, $1)) * 255) }
    }
}

// MARK: - Calendar sets

/// Switches between saved groups of calendars, and saves the current selection as a new one.
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
            Button("Save Current Calendars as Set…", systemImage: "plus") { name = ""; naming = true }
            if !sets.isEmpty { Button("Manage Sets…", systemImage: "slider.horizontal.3") { managing = true } }
        } label: {
            Label(sets.first { $0.id == active }?.name ?? "Calendar sets", systemImage: active == nil ? "square.stack" : "square.stack.fill")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Calendar sets")
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
                if sets.isEmpty { Text("No sets yet. Use Save Current Calendars as Set in the Calendar tab's set menu.").foregroundStyle(.secondary) }
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
/// which shows all calendars.
struct CalendarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Show a Calendar Set"
    static let description: IntentDescription? = "Shows only the calendars and reminder lists in a set while this Focus is on."
    @Parameter(title: "Calendar Set") var calendarSet: CalendarSetEntity?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(calendarSet?.name ?? "All Calendars")")
    }
    func perform() async throws -> some IntentResult {
        CalendarSet.apply(CalendarSet.saved.first { $0.id.uuidString == calendarSet?.id })
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
