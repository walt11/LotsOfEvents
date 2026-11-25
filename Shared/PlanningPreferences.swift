import Foundation
import EventKit

/// Local planning preferences shared by the app and widgets.
enum PlanningPreferences {
    static let hiddenContactDates = "hiddenContactDates"
    static let contactAlerts = "contactDateAlertDays"
    static func contactIsVisible(_ id: String) -> Bool {
        !(Preferences.defaults.stringArray(forKey: hiddenContactDates) ?? []).contains(id)
    }
    static func setContact(_ id: String, visible: Bool) {
        var hidden = Set(Preferences.defaults.stringArray(forKey: hiddenContactDates) ?? [])
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        Preferences.defaults.set(Array(hidden), forKey: hiddenContactDates)
    }
    private static let bufferPrefixes = ["planning.travel.", "planning.preparation."]
    /// Tied to the event, or to the occurrence's original date in a series, so moving the event keeps its time.
    static func bufferKey(_ event: EKEvent, travel: Bool) -> String {
        let occurrence = event.hasRecurrenceRules || event.isDetached ? String(Int((event.occurrenceDate ?? event.startDate).timeIntervalSince1970)) : "single"
        return "planning.\(travel ? "travel" : "preparation").\(event.calendarItemIdentifier).\(occurrence)"
    }
    /// Earlier builds keyed these by the start time, which was lost whenever the event moved.
    private static func legacyBufferKey(_ event: EKEvent, travel: Bool) -> String {
        "planning.\(travel ? "travel" : "preparation").\(event.calendarItemIdentifier).\(event.startDate.timeIntervalSince1970)"
    }
    static func buffer(_ event: EKEvent, travel: Bool, in defaults: UserDefaults = Preferences.defaults) -> Int {
        guard event.startDate != nil else { return 0 }
        let key = bufferKey(event, travel: travel)
        if let value = defaults.object(forKey: key) as? Int { return value }
        let legacy = legacyBufferKey(event, travel: travel)
        let value = defaults.integer(forKey: legacy)
        if defaults.object(forKey: legacy) != nil {
            defaults.set(value, forKey: key)
            defaults.removeObject(forKey: legacy)
        }
        return value
    }
    static func setBuffer(_ event: EKEvent, travel: Bool, minutes: Int, in defaults: UserDefaults = Preferences.defaults) {
        defaults.removeObject(forKey: legacyBufferKey(event, travel: travel))
        if minutes > 0 { defaults.set(minutes, forKey: bufferKey(event, travel: travel)) }
        else { defaults.removeObject(forKey: bufferKey(event, travel: travel)) }
    }
    static func bufferMinutes(_ event: EKEvent) -> Int { buffer(event, travel: true) + buffer(event, travel: false) }
    /// Drops saved times for occurrences long past and for events that no longer exist.
    static func pruneBuffers(store: EKEventStore, now: Date = .now, in defaults: UserDefaults = Preferences.defaults) {
        let cutoff = now.addingTimeInterval(-60 * 86400).timeIntervalSince1970
        for key in defaults.dictionaryRepresentation().keys where bufferPrefixes.contains(where: key.hasPrefix) {
            if key.hasSuffix(".single") {
                let id = String(key.dropLast(".single".count)).components(separatedBy: ".").dropFirst(2).joined(separator: ".")
                if store.calendarItem(withIdentifier: id) == nil { defaults.removeObject(forKey: key) }
            } else if let stamp = key.range(of: #"\d+(\.\d+)?$"#, options: .regularExpression).flatMap({ Double(key[$0]) }), stamp < cutoff {
                defaults.removeObject(forKey: key)
            }
        }
    }
    static func insufficientGap(previousEnd: Date, nextStart: Date, minutes: Int) -> Bool {
        nextStart.timeIntervalSince(previousEnd) < Double(minutes * 60)
    }
}

/// Plain-text payloads are namespaced so dragging unrelated text cannot change a task.
enum ReminderDrag {
    static let prefix = "lotsofevents-task:"
    static func payload(_ id: String) -> String { prefix + id }
    static func identifier(_ payload: String) -> String? {
        guard payload.hasPrefix(prefix), payload.count > prefix.count else { return nil }
        return String(payload.dropFirst(prefix.count))
    }
}
