import Foundation
import EventKit
import ActivityKit

/// Finds a video-call link (Zoom, Google Meet, Teams, Webex, FaceTime, and others) in an event's URL, location, or notes.
enum MeetingLink {
    private static let hosts = ["zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                "facetime.apple.com", "whereby.com", "gotomeeting.com", "meet.goto.com", "bluejeans.com", "chime.aws", "around.co"]
    static func url(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        for text in [location, notes].compactMap({ $0 }) where !text.isEmpty {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if let found = matches.compactMap(\.url).first(where: isMeeting) { return found }
        }
        return nil
    }
    static func url(for event: EKEvent) -> URL? { url(url: event.url, location: event.location, notes: event.notes) }
    static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// The service's name for the Join button, e.g. "Zoom".
    static func service(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        return "Call"
    }
}

/// Timed items that overlap another timed item on the same day.
enum Conflicts {
    static func ids(_ spans: [(id: String, start: Date, end: Date)]) -> Set<String> {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result = Set<String>()
        var latest: (id: String, end: Date)?
        for span in sorted {
            if let current = latest, span.start < current.end {
                result.insert(span.id)
                result.insert(current.id)
            }
            if latest.map({ span.end > $0.end }) ?? true { latest = (span.id, span.end) }
        }
        return result
    }
}

/// True when the event is an invitation the user hasn't answered.
extension EKEvent {
    var needsReply: Bool {
        guard hasAttendees, let me = attendees?.first(where: \.isCurrentUser) else { return false }
        return me.participantStatus == .pending
    }
    var isBirthday: Bool { calendar?.type == .birthday }
}

/// A named group of calendars and reminder lists, like "Work" or "Personal", stored as the ones it hides
/// so calendars added later appear in every set.
struct CalendarSet: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var hiddenCalendars: [String]
    var hiddenLists: [String]

    static let key = "calendarSets"
    static let activeKey = "activeCalendarSet"
    static var saved: [CalendarSet] {
        get { (Preferences.defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([CalendarSet].self, from: $0) } ?? [] }
        set { Preferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    static var activeID: UUID? {
        get { Preferences.defaults.string(forKey: activeKey).flatMap(UUID.init) }
        set { Preferences.defaults.set(newValue?.uuidString, forKey: activeKey) }
    }
    /// The calendars and lists shown right now, as a set to save.
    static func current(named name: String, in store: UserDefaults = Preferences.defaults) -> CalendarSet {
        CalendarSet(name: name, hiddenCalendars: store.stringArray(forKey: "hiddenCalendars") ?? [],
                    hiddenLists: store.stringArray(forKey: "hiddenReminderLists") ?? [])
    }
    /// Shows this set's calendars and lists. `nil` shows everything.
    static func apply(_ set: CalendarSet?, in store: UserDefaults = Preferences.defaults) {
        store.set(set?.hiddenCalendars ?? [], forKey: "hiddenCalendars")
        store.set(set?.hiddenLists ?? [], forKey: "hiddenReminderLists")
        store.set(0, forKey: "page")
        activeID = set?.id
    }
}

/// The Live Activity for the next event: a countdown on the Lock Screen and in the Dynamic Island.
struct NextEventAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var colorRGB: Int
        var joinURL: URL?
    }
    /// Which event the activity follows, so a moved or different event replaces it.
    var eventID: String
}
