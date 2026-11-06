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
    static func bufferKey(_ event: EKEvent, travel: Bool) -> String {
        "planning.\(travel ? "travel" : "preparation").\(event.calendarItemIdentifier).\(event.startDate.timeIntervalSince1970)"
    }
    static func bufferMinutes(_ event: EKEvent) -> Int {
        Preferences.defaults.integer(forKey: bufferKey(event, travel: true)) + Preferences.defaults.integer(forKey: bufferKey(event, travel: false))
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
