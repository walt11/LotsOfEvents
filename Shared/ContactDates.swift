import Foundation
import EventKit
import SwiftUI

/// Only names and dated fields are cached locally in the app group for widgets.
struct ContactDateRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let contactID: String
    let name: String
    let label: String
    let components: DateComponents
    let birthday: Bool
    var title: String { "\(name) · \(label)" }

    /// Repeats in the date's own calendar, using local all-day boundaries. Dates without a year work too.
    func occurrences(in range: DateInterval, timeZone: TimeZone = .current) -> [Date] {
        guard let month = components.month, let day = components.day, day > 0 else { return [] }
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var year = calendar.dateInterval(of: .year, for: range.start) else { return [] }
        var result: [Date] = []
        while year.start < range.end {
            var candidate = calendar.dateComponents([.era, .year], from: year.start)
            candidate.month = month; candidate.day = 1
            candidate.isLeapMonth = components.isLeapMonth
            if let first = calendar.date(from: candidate), calendar.component(.month, from: first) == month,
               let days = calendar.range(of: .day, in: .month, for: first) {
                // February 29 anniversaries appear on February 28 in non-leap years.
                candidate.day = min(day, days.count)
                if let date = calendar.date(from: candidate), date >= range.start, date < range.end,
                   components.year == nil || components.year! <= (candidate.year ?? 0) {
                    result.append(calendar.startOfDay(for: date))
                }
            }
            guard let next = calendar.dateInterval(of: .year, for: year.end), next.end > year.end else { break }
            year = next
        }
        return result
    }
}

enum ContactDates {
    static let enabledKey = "contactDatesEnabled"
    static let cacheKey = "contactDatesCache"
    static var enabled: Bool { Preferences.defaults.bool(forKey: enabledKey) }
    static var records: [ContactDateRecord] {
        guard enabled, let data = Preferences.defaults.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([ContactDateRecord].self, from: data)) ?? []
    }
    static func items(in range: DateInterval, excludingBirthdays: Set<String> = [], records: [ContactDateRecord]? = nil) -> [AgendaItem] {
        (records ?? Self.records).flatMap { record -> [AgendaItem] in
            guard !record.birthday || !excludingBirthdays.contains(record.contactID) else { return [] }
            return record.occurrences(in: range).map { date in
                AgendaItem(id: "contact-date:\(record.id):\(date.timeIntervalSince1970)", title: record.title,
                           date: date, allDay: true, reminder: false, source: "Contacts", color: .purple,
                           notes: "From Contacts · repeats every year", endDate: Calendar.current.date(byAdding: .day, value: 1, to: date),
                           birthday: record.birthday, blocksAvailability: false, contactDateID: record.id)
            }
        }
    }
    static func events(store: EKEventStore, in range: DateInterval, excludingBirthdays: Set<String> = []) -> [EKEvent] {
        let source = EKCalendar(for: .event, eventStore: store)
        source.title = "Contacts"; source.cgColor = CGColor(red: 0.64, green: 0.40, blue: 0.73, alpha: 1)
        return items(in: range, excludingBirthdays: excludingBirthdays).map { item in
            let event = EKEvent(eventStore: store)
            event.title = item.title; event.startDate = item.date; event.endDate = item.endDate
            event.isAllDay = true; event.availability = .free; event.calendar = source
            event.notes = item.notes
            var url = URLComponents(); url.scheme = "lotsofevents"; url.host = "contact-date"
            url.queryItems = [URLQueryItem(name: "id", value: item.contactDateID)]
            event.url = url.url
            return event
        }
    }
}

extension EKEvent {
    var contactDateID: String? {
        guard let url, url.scheme == "lotsofevents", url.host == "contact-date" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
