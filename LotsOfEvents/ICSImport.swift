import SwiftUI
import EventKit
import UniformTypeIdentifiers

/// One event read from an .ics file, before it is added to a calendar.
struct ICSEvent: Identifiable, Hashable {
    var id = UUID()
    var uid: String?
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    /// The raw RRULE value, turned into a rule when the event is saved.
    var recurrence: String?
    /// Alerts as seconds before (negative) or after the start.
    var alertOffsets: [TimeInterval] = []
    /// A blocked import is displayed with a reason rather than silently changing its schedule.
    var importIssue: String? = nil

    /// "Thu, Oct 29 · 9:00 AM – 10:00 AM", or "Thu, Oct 29 · All day".
    var summary: String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        if allDay {
            let last = Calendar.current.date(byAdding: .second, value: -1, to: end) ?? end
            if Calendar.current.isDate(last, inSameDayAs: start) { return "\(day) · All day" }
            return "\(day) – \(last.formatted(.dateTime.month(.abbreviated).day())) · All day"
        }
        return "\(day) · \(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Reads the events in an iCalendar (.ics) file: titles, times and time zones, all-day events,
/// repeats, alerts, places, notes, and links. Unsupported recurrence exceptions are blocked with an explanation.
enum ICSParser {
    static func parse(_ text: String, defaultZone: TimeZone = .current) -> [ICSEvent] {
        var events: [ICSEvent] = []
        var stack: [String] = []
        var fields: [(name: String, params: [String: String], value: String)] = []
        var alarms: [TimeInterval] = []
        var exceptionIDs = Set<String>()
        for line in unfold(text) {
            guard let (name, params, value) = split(line) else { continue }
            switch name {
            case "BEGIN":
                stack.append(value.uppercased())
                if value.uppercased() == "VEVENT" { fields = []; alarms = [] }
            case "END":
                let ended = stack.popLast()
                if ended == "VEVENT" {
                    if fields.contains(where: { ["RECURRENCE-ID", "EXDATE", "RDATE"].contains($0.name) }),
                       let uid = fields.first(where: { $0.name == "UID" })?.value { exceptionIDs.insert(uid) }
                    if let event = makeEvent(fields, alarms: alarms, zone: defaultZone) { events.append(event) }
                }
            case "TRIGGER" where stack.last == "VALARM":
                // Only alerts relative to the start; "RELATED=END" and fixed times are rare and skipped.
                if params["VALUE"] != "DATE-TIME", params["RELATED"] != "END", let offset = duration(value) { alarms.append(offset) }
            default:
                if stack.last == "VEVENT" { fields.append((name, params, value)) }
            }
        }
        return events.map { event in
            var event = event
            if let uid = event.uid, exceptionIDs.contains(uid) {
                event.importIssue = "This series contains changed, cancelled, or additional occurrences. Import it with Apple Calendar to preserve those changes."
            }
            return event
        }
    }

    private static func makeEvent(_ fields: [(name: String, params: [String: String], value: String)], alarms: [TimeInterval], zone: TimeZone) -> ICSEvent? {
        func field(_ name: String) -> (params: [String: String], value: String)? {
            fields.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        if field("STATUS")?.value.uppercased() == "CANCELLED" { return nil }
        guard let startField = field("DTSTART"), let (start, allDay) = date(startField.value, params: startField.params, zone: zone) else { return nil }
        var end: Date
        if let endField = field("DTEND"), let (parsed, _) = date(endField.value, params: endField.params, zone: zone), parsed >= start {
            end = parsed
        } else if let length = field("DURATION").flatMap({ duration($0.value) }), length >= 0 {
            end = start.addingTimeInterval(length)
        } else {
            end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start
        }
        if allDay && end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: start)! }
        let title = field("SUMMARY").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 } ?? "New Event"
        // Keep exceptions visible in the preview, but never save them as unrelated standalone events.
        let isRecurrenceCopy = field("RECURRENCE-ID") != nil
        let hasExceptions = fields.contains { ["RECURRENCE-ID", "EXDATE", "RDATE"].contains($0.name) }
        let unsupportedRule = field("RRULE").map { recurrenceRule($0.value, zone: zone) == nil } ?? false
        let issue = hasExceptions ? "This event has recurrence exceptions. Import it with Apple Calendar to preserve them."
            : unsupportedRule ? "This repeat pattern is not supported. Import it with Apple Calendar to preserve the schedule." : nil
        return ICSEvent(uid: field("UID")?.value, title: title, start: start, end: end, allDay: allDay,
                        location: field("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                        notes: field("DESCRIPTION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                        url: field("URL").flatMap { URL(string: $0.value) },
                        recurrence: isRecurrenceCopy ? nil : field("RRULE")?.value,
                        alertOffsets: alarms, importIssue: issue)
    }

    /// Joins folded lines (a line starting with a space or tab continues the one before it).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// "DTSTART;TZID=America/Chicago:20261029T090000" → ("DTSTART", ["TZID": "America/Chicago"], "20261029T090000").
    static func split(_ line: String) -> (String, [String: String], String)? {
        var inQuotes = false
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            else if character == ":" && !inQuotes { colon = index; break }
        }
        guard let colon else { return nil }
        let parts = line[..<colon].split(separator: ";", omittingEmptySubsequences: true)
        guard let name = parts.first else { return nil }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name.uppercased(), params, String(line[line.index(after: colon)...]))
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A date or date-time in UTC ("Z"), a named time zone, or floating (the default zone). Returns whether it is a whole day.
    static func date(_ value: String, params: [String: String], zone: TimeZone) -> (Date, Bool)? {
        let value = value.trimmingCharacters(in: .whitespaces)
        let allDay = params["VALUE"] == "DATE" || !value.contains("T")
        let pattern = allDay ? #"^[0-9]{8}$"# : #"^[0-9]{8}T[0-9]{6}Z?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let digits = value.filter(\.isNumber)
        var calendar = Calendar(identifier: .gregorian)
        if value.hasSuffix("Z") { calendar.timeZone = TimeZone(identifier: "UTC")! }
        else if !allDay, let id = params["TZID"] { calendar.timeZone = timeZone(id) ?? zone }
        else { calendar.timeZone = zone }
        func number(_ from: Int, _ length: Int) -> Int? {
            guard from >= 0, from + length <= digits.count else { return nil }
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)])
        }
        var parts = DateComponents(year: number(0, 4), month: number(4, 2), day: number(6, 2))
        if !allDay { parts.hour = number(8, 2) ?? 0; parts.minute = number(10, 2) ?? 0; parts.second = number(12, 2) ?? 0 }
        guard parts.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: parts).map { ($0, allDay) }
    }

    /// An IANA name, with the "/mozilla.org/…" style prefixes some apps add, or a common Windows name from Outlook.
    static func timeZone(_ id: String) -> TimeZone? {
        if let zone = TimeZone(identifier: id) { return zone }
        let pieces = id.split(separator: "/")
        if pieces.count >= 2, let zone = TimeZone(identifier: pieces.suffix(2).joined(separator: "/")) { return zone }
        let windows = ["Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
                       "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
                       "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
                       "Hawaiian Standard Time": "Pacific/Honolulu", "GMT Standard Time": "Europe/London",
                       "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
                       "Central European Standard Time": "Europe/Warsaw", "India Standard Time": "Asia/Kolkata",
                       "Tokyo Standard Time": "Asia/Tokyo", "China Standard Time": "Asia/Shanghai",
                       "AUS Eastern Standard Time": "Australia/Sydney", "UTC": "UTC"]
        return windows[id].flatMap(TimeZone.init(identifier:))
    }

    /// "-PT15M" → -900, "P1DT2H" → 93600, "P1W" → 604800.
    static func duration(_ value: String) -> TimeInterval? {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()
        var sign: TimeInterval = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        for character in text.dropFirst() {
            if character.isNumber { number.append(character); continue }
            let amount = TimeInterval(number) ?? 0
            number = ""
            switch character {
            case "W": total += amount * 604_800
            case "D": total += amount * 86_400
            case "H": total += amount * 3_600
            case "M": total += amount * 60
            case "S": total += amount
            case "T": continue
            default: return nil
            }
        }
        return total.isFinite ? sign * total : nil
    }

    /// An RRULE value as an EventKit repeat rule, e.g. "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10".
    static func recurrenceRule(_ value: String, zone: TimeZone = .current) -> EKRecurrenceRule? {
        var parts: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let items = pair.split(separator: "=", maxSplits: 1)
            if items.count == 2 { parts[items[0].uppercased()] = String(items[1]) }
        }
        // WKST (the week's first day) is in nearly every Google and Outlook rule; EventKit takes it from the calendar, so it's ignored.
        let supported: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYWEEKNO", "BYYEARDAY", "BYSETPOS", "COUNT", "UNTIL", "WKST"]
        guard Set(parts.keys).isSubset(of: supported) else { return nil }
        for key in ["INTERVAL", "COUNT"] {
            if let value = parts[key], Int(value).map({ $0 > 0 }) != true { return nil }
        }
        if parts["COUNT"] != nil && parts["UNTIL"] != nil { return nil }
        if let until = parts["UNTIL"], date(until, params: [:], zone: zone) == nil { return nil }
        for (key, limit, allowsNegative) in [("BYMONTHDAY", 31, true), ("BYMONTH", 12, false), ("BYWEEKNO", 53, true), ("BYYEARDAY", 366, true), ("BYSETPOS", 366, true)] {
            if let value = parts[key] {
                let values = value.split(separator: ",", omittingEmptySubsequences: false)
                guard !values.isEmpty, values.allSatisfy({ part in
                    guard let number = Int(part) else { return false }
                    return number != 0 && number <= limit && number >= (allowsNegative ? -limit : 1)
                }) else { return nil }
            }
        }
        if let days = parts["BYDAY"] {
            guard days.split(separator: ",", omittingEmptySubsequences: false).allSatisfy({
                $0.range(of: #"^([+-]?[1-9]|[+-]?[1-4][0-9]|[+-]?5[0-3])?(SU|MO|TU|WE|TH|FR|SA)$"#, options: .regularExpression) != nil
            }) else { return nil }
        }
        let frequency: EKRecurrenceFrequency
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: return nil
        }
        let weekdays = ["SU": EKWeekday.sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday, "TH": .thursday, "FR": .friday, "SA": .saturday]
        let days: [EKRecurrenceDayOfWeek]? = parts["BYDAY"].map { list in
            list.split(separator: ",").compactMap { item in
                let item = item.uppercased()
                guard let day = weekdays[String(item.suffix(2))] else { return nil }
                let week = Int(item.dropLast(2)) ?? 0
                return week == 0 ? EKRecurrenceDayOfWeek(day) : EKRecurrenceDayOfWeek(day, weekNumber: week)
            }
        }
        func numbers(_ key: String) -> [NSNumber]? {
            parts[key].map { $0.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) } }
        }
        var end: EKRecurrenceEnd?
        if let count = parts["COUNT"].flatMap(Int.init) { end = EKRecurrenceEnd(occurrenceCount: count) }
        else if let until = parts["UNTIL"], let (date, _) = date(until, params: [:], zone: zone) { end = EKRecurrenceEnd(end: date) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: max(1, Int(parts["INTERVAL"] ?? "") ?? 1),
                                daysOfTheWeek: days?.isEmpty == false ? days : nil, daysOfTheMonth: numbers("BYMONTHDAY"),
                                monthsOfTheYear: numbers("BYMONTH"), weeksOfTheYear: numbers("BYWEEKNO"),
                                daysOfTheYear: numbers("BYYEARDAY"), setPositions: numbers("BYSETPOS"), end: end)
    }

    static func data(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
    /// Reads a shared or picked file. Files from Files may need security-scoped access.
    static func events(at url: URL) throws -> [ICSEvent] {
        let data = try data(at: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(text)
    }
}

extension UTType {
    static let ics = UTType("com.apple.ical.ics") ?? .calendarEvent
}

/// The sheet shown after sharing an .ics file to the app or its share extension: the events it holds,
/// which calendar to add them to, and Add.
struct ICSImportView: View {
    let store: EKEventStore
    let events: [ICSEvent]
    /// Closes the sheet; the share extension passes its own, since it isn't presented by SwiftUI.
    var finish: (() -> Void)? = nil
    /// Supported events start checked; blocked series remain visible with an explanation.
    @State private var chosen: Set<UUID>
    @State private var existing: Set<UUID> = []
    @State private var calendarID = ""
    @State private var loaded = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: EKEventStore, events: [ICSEvent], finish: (() -> Void)? = nil) {
        self.store = store
        self.events = events
        self.finish = finish
        _chosen = State(initialValue: Set(events.filter { $0.importIssue == nil }.map(\.id)))
    }
    private var calendars: [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    ContentUnavailableView("No events found", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("This file doesn't contain any events that can be added."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        Picker("Calendar", selection: $calendarID) {
                            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                Label { Text(calendar.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor)) }
                                    .tag(calendar.calendarIdentifier)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .foregroundStyle(GalleryPalette.ink)
                    }
                    .listRowBackground(GalleryPalette.card)
                    Section {
                        ForEach(events) { event in row(event) }
                    } header: {
                        SectionHeader(title: events.count == 1 ? "1 event" : "\(events.count) events",
                                      trailing: existing.isEmpty ? nil : "\(existing.count) already added")
                    }
                    .listRowBackground(GalleryPalette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GalleryPalette.paper)
            .navigationTitle("Add to Calendar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count > 1 ? "Add \(chosen.count)" : "Add", action: save).disabled(chosen.isEmpty || calendarID.isEmpty)
                }
            }
            .alert("Unable to add events", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear(perform: load)
        }
    }
    private func row(_ event: ICSEvent) -> some View {
        let selected = chosen.contains(event.id)
        return Button {
            if selected { chosen.remove(event.id) } else { chosen.insert(event.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(GalleryPalette.muted))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(event.title).font(.subheadline.weight(.medium)).foregroundStyle(GalleryPalette.ink)
                        if event.recurrence != nil { Image(systemName: "repeat").font(.caption).foregroundStyle(GalleryPalette.muted).accessibilityLabel("Repeats") }
                    }
                    Text(event.summary).font(.caption).foregroundStyle(GalleryPalette.muted)
                    if let location = event.location { Text(location).font(.caption).foregroundStyle(GalleryPalette.muted).lineLimit(1) }
                    if let issue = event.importIssue { Text(issue).font(.caption).foregroundStyle(GalleryPalette.warning) }
                    if existing.contains(event.id) { Text("Already in your calendar").font(.caption.weight(.medium)).foregroundStyle(GalleryPalette.warning) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(event.importIssue != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func close() { if let finish { finish() } else { dismiss() } }
    private func load() {
        guard !loaded else { return }
        loaded = true
        calendarID = store.defaultCalendarForNewEvents?.calendarIdentifier ?? calendars.first?.calendarIdentifier ?? ""
        // Events with the same title and start as one already in any calendar are noted, so sharing a file twice is easy to spot.
        for event in events {
            let window = store.predicateForEvents(withStart: event.start.addingTimeInterval(-60), end: event.end.addingTimeInterval(60), calendars: nil)
            if store.events(matching: window).contains(where: { $0.title == event.title && abs($0.startDate.timeIntervalSince(event.start)) < 60 }) {
                existing.insert(event.id)
            }
        }
    }
    private func save() {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return }
        do {
            for event in events where chosen.contains(event.id) && event.importIssue == nil {
                let item = EKEvent(eventStore: store)
                item.calendar = calendar
                item.title = event.title
                item.isAllDay = event.allDay
                item.startDate = event.start
                // EventKit's all-day end is the last day itself; the file's end is the morning after.
                item.endDate = event.allDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end
                item.location = event.location
                item.notes = event.notes
                item.url = event.url
                if let rule = event.recurrence.flatMap({ ICSParser.recurrenceRule($0) }) { item.addRecurrenceRule(rule) }
                for offset in event.alertOffsets { item.addAlarm(EKAlarm(relativeOffset: offset)) }
                try store.save(item, span: event.recurrence == nil ? .thisEvent : .futureEvents, commit: false)
            }
            try store.commit()
            close()
        } catch {
            store.reset()
            self.error = error.localizedDescription
        }
    }
}
