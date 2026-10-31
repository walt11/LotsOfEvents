import SwiftUI
import EventKit
import EventKitUI

/// An event's details on the Mac, drawn by the app so it opens at once. Apple's event view on the Mac loads its
/// contents a moment after its sheet appears, so the sheet sat blank first. Edit still opens Apple's editor.
struct MacEventDetails: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    let event: EKEvent
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false
    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        row("clock", when)
                        if let rule = event.recurrenceRules?.first { row("repeat", Self.repeatText(rule)) }
                        row("calendar", event.calendarTitle, tint: event.calendarColor)
                        if let place = event.location, !place.isEmpty, MeetingLink.url(url: nil, location: place, notes: nil) == nil {
                            row("mappin.and.ellipse", place)
                        }
                        if let link = event.url, !MeetingLink.isMeeting(link) { linkRow(link) }
                        let alerts = (event.alarms ?? []).map(Self.alertText)
                        if !alerts.isEmpty { row("bell", alerts.formatted(.list(type: .and))) }
                        if event.availability == .free { row("cup.and.saucer", "Shown as free") }
                    }
                    .gallerySurface(radius: 14)
                    actions
                    if let attendees = event.attendees, !attendees.isEmpty { invitees(attendees) }
                    if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "Notes")
                            Text(notes).font(.callout).foregroundStyle(GalleryPalette.ink).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).gallerySurface(radius: 14)
                        }
                    }
                }
                .padding(20)
            }
            .background(GalleryPalette.paper)
            .navigationTitle("Event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.keyboardShortcut(.cancelAction) }
                if event.isWritable {
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.keyboardShortcut("e") }
                }
            }
            .tint(accent)
            .sheet(isPresented: $editing) {
                ExistingEventEditor(store: model.store, event: event) { deleted in
                    editing = false
                    if deleted { close() }
                    model.scheduleRefresh()
                }
            }
            .confirmationDialog(event.hasRecurrenceRules ? "This is a repeating event." : "Delete “\(event.title ?? "Event")”?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                if event.hasRecurrenceRules {
                    Button("Delete This Event Only", role: .destructive) { delete(.thisEvent) }
                    Button("Delete All Future Events", role: .destructive) { delete(.futureEvents) }
                } else {
                    Button("Delete Event", role: .destructive) { delete(.thisEvent) }
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 460, idealWidth: embedded ? 340 : 500, minHeight: 480, idealHeight: 600)
    }

    private func close() {
        if embedded { model.inspectorSelection = nil } else { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(event.calendarColor).frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if event.isBirthday { Image(systemName: "gift.fill").foregroundStyle(event.calendarColor) }
                    Text(event.title ?? "Event").font(.title2.bold()).foregroundStyle(GalleryPalette.ink).textSelection(.enabled)
                }
                Text(event.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.subheadline).foregroundStyle(GalleryPalette.muted)
                EventBadges(needsReply: event.needsReply, conflict: false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "9:00 – 10:00 AM", "All day", or the full span for an event that runs over several days.
    private var when: String {
        let multiDay = !calendar.isDate(event.startDate, inSameDayAs: event.endDate.addingTimeInterval(event.isAllDay ? -1 : 0))
        if event.isAllDay {
            return multiDay ? "All day, until \(event.endDate.addingTimeInterval(-1).formatted(.dateTime.weekday(.wide).month().day()))" : "All day"
        }
        if multiDay { return (event.startDate..<event.endDate).formatted(.interval.weekday().month().day().hour().minute()) }
        var text = event.timeRange
        if let zone = event.timeZone, zone.secondsFromGMT(for: event.startDate) != TimeZone.current.secondsFromGMT(for: event.startDate) {
            text += " (\(zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier))"
        }
        return text
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = MeetingLink.url(for: event), event.endDate > .now { JoinButton(url: link) }
            if let place = event.location, !place.isEmpty, MeetingLink.url(url: nil, location: place, notes: nil) == nil {
                Button { directions() } label: {
                    Label("Directions\(TravelAlerts.estimates[event.occurrenceKey].map { " · \(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))" } ?? "")",
                          systemImage: "car.fill")
                }
            }
            Button { model.sheet = .duplicate(event) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if event.isWritable && !event.isBirthday {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
    }

    private func invitees(_ attendees: [EKParticipant]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Invitees", trailing: "\(attendees.count)")
            VStack(alignment: .leading, spacing: 0) {
                if let organizer = event.organizer { person(organizer, note: "Organizer") }
                ForEach(Array(attendees.enumerated()), id: \.offset) { _, person in self.person(person, note: person.isCurrentUser ? "You" : nil) }
            }
            .gallerySurface(radius: 14)
        }
    }

    private func person(_ participant: EKParticipant, note: String?) -> some View {
        let (symbol, color): (String, Color) = switch participant.participantStatus {
        case .accepted: ("checkmark.circle.fill", .green)
        case .declined: ("xmark.circle.fill", .red)
        case .tentative: ("questionmark.circle.fill", .orange)
        default: ("clock", GalleryPalette.muted)
        }
        let name = participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(name).font(.subheadline).foregroundStyle(GalleryPalette.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let note { Text(note).font(.caption).foregroundStyle(GalleryPalette.muted) }
        }
        .padding(.horizontal, 12).frame(minHeight: 34)
    }

    private func row(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint ?? GalleryPalette.muted).frame(width: 20)
            Text(text).font(.subheadline).foregroundStyle(GalleryPalette.ink).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func linkRow(_ link: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "link").foregroundStyle(GalleryPalette.muted).frame(width: 20)
            Link(link.host() ?? link.absoluteString, destination: link).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func delete(_ span: EKSpan) {
        model.delete(event, span: span)
        close()
    }

    private func directions() {
        let query = event.structuredLocation?.geoLocation.map { "daddr=\($0.coordinate.latitude),\($0.coordinate.longitude)" }
            ?? "daddr=\((event.location ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let url = URL(string: "maps://?\(query)") { UIApplication.shared.open(url) }
    }

    /// "Every week on Monday and Wednesday, until Dec 31, 2026".
    static func repeatText(_ rule: EKRecurrenceRule) -> String {
        let unit = switch rule.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        @unknown default: "time"
        }
        var text = rule.interval <= 1 ? "Every \(unit)" : "Every \(rule.interval) \(unit)s"
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let symbols = Calendar.current.weekdaySymbols
            text += " on " + days.map { day in
                let name = symbols[day.dayOfTheWeek.rawValue - 1]
                switch day.weekNumber {
                case 0: return name
                case -1: return "the last \(name)"
                default: return "the \(day.weekNumber.formatted(.number))\(ordinalSuffix(day.weekNumber)) \(name)"
                }
            }.formatted(.list(type: .and))
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate { text += ", until \(date.formatted(date: .abbreviated, time: .omitted))" }
            else if end.occurrenceCount > 0 { text += ", \(end.occurrenceCount) times" }
        }
        return text
    }
    private static func ordinalSuffix(_ number: Int) -> String {
        switch (number % 100, number % 10) {
        case (11...13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
    }

    /// "15 minutes before", "At time of event", or the alert's date.
    static func alertText(_ alarm: EKAlarm) -> String {
        if let date = alarm.absoluteDate { return date.formatted(date: .abbreviated, time: .shortened) }
        let offset = alarm.relativeOffset
        if offset == 0 { return "At time of event" }
        let amount = Duration.seconds(abs(offset)).formatted(.units(allowed: [.weeks, .days, .hours, .minutes], width: .wide))
        return offset < 0 ? "\(amount) before" : "\(amount) after"
    }
}

/// Apple's editor for an existing event. Reports whether the event was deleted from inside it.
struct ExistingEventEditor: UIViewControllerRepresentable {
    @AppAccent private var accent
    let store: EKEventStore
    let event: EKEvent
    let finished: (_ deleted: Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = event
        editor.view.tintColor = UIColor(accent)
        editor.editViewDelegate = context.coordinator
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finished: (Bool) -> Void
        init(finished: @escaping (Bool) -> Void) { self.finished = finished }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            finished(action == .deleted)
        }
    }
}
