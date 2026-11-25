import Foundation
import EventKit
import WidgetKit

struct WidgetUndoRecord: Codable {
    let token: String
    let identifier: String
    let title: String
    let completedAt: Date
    var expires: Date { completedAt.addingTimeInterval(30) }
    static let key = "widgetCompletionUndo"
    static var current: Self? {
        guard let data = Preferences.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() { if let data = try? JSONEncoder().encode(self) { Preferences.defaults.set(data, forKey: Self.key) } }
    static func undo(token: String) throws {
        guard let record = current, record.token == token, record.expires > .now else { return }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: record.identifier) as? EKReminder,
              reminder.isCompleted, reminder.calendar?.allowsContentModifications == true,
              let completion = reminder.completionDate, abs(completion.timeIntervalSince(record.completedAt)) < 5 else { return }
        reminder.isCompleted = false
        try store.save(reminder, commit: true)
        Preferences.defaults.removeObject(forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
