import Foundation
import Contacts
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
    var symbol: String {
        if birthday { return "gift.fill" }
        let anniversary = CNLabeledValue<NSString>.localizedString(forLabel: CNLabelDateAnniversary)
        return label.localizedCaseInsensitiveContains("anniversary") || label.localizedCaseInsensitiveCompare(anniversary) == .orderedSame
            ? "heart.fill" : "calendar"
    }
    var title: String { "\(name) · \(label)" }

    /// Chinese-calendar years repeat every 60; the era says which cycle a year is in.
    private func elapsedYears(to year: DateComponents, calendar: Calendar) -> Int? {
        guard let originalYear = components.year, originalYear > 0, let current = year.year else { return nil }
        guard calendar.identifier == .chinese else { return current - originalYear }
        guard let originalEra = components.era, let currentEra = year.era else { return nil }
        return (currentEra - originalEra) * 60 + current - originalYear
    }

    /// Use the occurrence year, so browsing future anniversaries shows the correct count.
    func title(on date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let years = elapsedYears(to: calendar.dateComponents([.era, .year], from: date), calendar: calendar), years > 0 else { return title }
        return "\(title) · \(years) \(years == 1 ? "year" : "years")"
    }

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
            // A date in a leap month is kept in the ordinary month in years that have no such leap month.
            if components.isLeapMonth == true, let leap = calendar.date(from: candidate),
               calendar.dateComponents([.month], from: leap).isLeapMonth != true { candidate.isLeapMonth = false }
            if let first = calendar.date(from: candidate), calendar.component(.month, from: first) == month,
               let days = calendar.range(of: .day, in: .month, for: first) {
                // February 29 anniversaries appear on February 28 in non-leap years.
                candidate.day = min(day, days.count)
                if let date = calendar.date(from: candidate), date >= range.start, date < range.end,
                   components.year == nil || (elapsedYears(to: candidate, calendar: calendar) ?? 0) >= 0 {
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
    static let colorKey = "contactDatesColor"
    static let defaultColor = 0x8E8E93
    static var cgColor: CGColor {
        let rgb = Preferences.defaults.object(forKey: colorKey) as? Int ?? defaultColor
        return CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static var color: Color { Color(cgColor: cgColor) }
    static let birthdayCalendarIDsKey = "contactBirthdayCalendarIDs"
    static func migrateSettings(in defaults: UserDefaults = Preferences.defaults) {
        guard defaults.object(forKey: "birthdayAges") != nil else { return }
        if defaults.bool(forKey: "birthdayAges") { defaults.set(true, forKey: enabledKey) }
        defaults.removeObject(forKey: "birthdayAges")
    }
    static var enabled: Bool { Preferences.defaults.bool(forKey: enabledKey) }
    static var records: [ContactDateRecord] { allRecords.filter { PlanningPreferences.contactIsVisible($0.id) } }
    private static let decodeLock = NSLock()
    nonisolated(unsafe) private static var decoded: (data: Data, records: [ContactDateRecord])?
    /// Decoded once per stored value, since calendar views ask for these on every fetch.
    static var allRecords: [ContactDateRecord] {
        guard enabled, let data = Preferences.defaults.data(forKey: cacheKey) else { return [] }
        decodeLock.lock(); defer { decodeLock.unlock() }
        if let decoded, decoded.data == data { return decoded.records }
        let records = (try? JSONDecoder().decode([ContactDateRecord].self, from: data)) ?? []
        decoded = (data, records)
        return records
    }
    static func items(in range: DateInterval, excludingBirthdays: Set<String> = [], records: [ContactDateRecord]? = nil) -> [AgendaItem] {
        (records ?? Self.records).flatMap { record -> [AgendaItem] in
            guard !record.birthday || !excludingBirthdays.contains(record.contactID) else { return [] }
            return record.occurrences(in: range).map { date in
                AgendaItem(id: "contact-date:\(record.id):\(date.timeIntervalSince1970)", title: record.title(on: date),
                           date: date, allDay: true, reminder: false, source: "Contacts", color: Self.color,
                           notes: "From Contacts · repeats every year", endDate: Calendar.current.date(byAdding: .day, value: 1, to: date),
                           birthday: record.birthday, blocksAvailability: false, contactDateID: record.id, contactDateSymbol: record.symbol)
            }
        }
    }
    static func events(store: EKEventStore, in range: DateInterval, excludingBirthdays: Set<String> = []) -> [EKEvent] {
        let source = EKCalendar(for: .event, eventStore: store)
        source.title = "Contacts"; source.cgColor = Self.cgColor
        return items(in: range, excludingBirthdays: excludingBirthdays).map { item in
            let event = EKEvent(eventStore: store)
            event.title = item.title; event.startDate = item.date; event.endDate = item.endDate
            event.isAllDay = true; event.availability = .free; event.calendar = source
            event.notes = item.notes
            var url = URLComponents(); url.scheme = "lotsofevents"; url.host = "contact-date"
            url.queryItems = [URLQueryItem(name: "id", value: item.contactDateID), URLQueryItem(name: "icon", value: item.contactDateSymbol)]
            event.url = url.url
            return event
        }
    }
}

extension EKEvent {
    var contactDateSymbol: String? {
        guard contactDateID != nil, let url else { return nil }
        let icon = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "icon" }?.value
        return ["gift.fill", "heart.fill", "calendar"].contains(icon ?? "") ? icon : "calendar"
    }
    var dateSymbol: String? { isBirthday ? "gift.fill" : contactDateSymbol }

    var contactDateID: String? {
        guard let url, url.scheme == "lotsofevents", url.host == "contact-date" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
