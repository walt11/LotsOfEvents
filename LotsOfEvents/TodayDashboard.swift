import SwiftUI
import EventKit

/// The top of the Agenda: today at a glance, with the day's schedule and every task
/// that needs attention (overdue, due today, and undated ones from the lists chosen for Today).
struct TodayDashboard: View {
    @ObservedObject var model: AgendaModel
    /// Today's rows from the agenda: events and reminders due today.
    let items: [AgendaItem]
    let overdue: [EKReminder]
    let undated: [EKReminder]
    private var events: [AgendaItem] { items.filter { !$0.reminder } }
    private var dueToday: [AgendaItem] { items.filter(\.reminder) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                header(context.date)
                schedule(context.date)
                tasks
            }
        }
    }

    private func header(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now.formatted(.dateTime.weekday(.wide))).font(.largeTitle.bold()).foregroundStyle(GalleryPalette.ink)
            Text(now.formatted(.dateTime.month(.wide).day().year())).font(.subheadline).foregroundStyle(GalleryPalette.muted)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 4)
    }

    private func card<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(GalleryPalette.muted) }
            }
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .gallerySurface(radius: 16)
    }

    private func schedule(_ now: Date) -> some View {
        let allDay = events.filter(\.allDay)
        let timed = events.filter { !$0.allDay }
        return card("SCHEDULE", trailing: events.isEmpty ? nil : "\(events.count) event\(events.count == 1 ? "" : "s")") {
            if events.isEmpty {
                Text(model.calendarAccess ? "No events today" : "Connect calendars to see events").font(.subheadline).foregroundStyle(GalleryPalette.muted)
            }
            if !allDay.isEmpty {
                // All-day events wrap as chips above the timed ones.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { ForEach(allDay) { chip($0) } }
                    VStack(alignment: .leading, spacing: 6) { ForEach(allDay) { chip($0) } }
                }
            }
            ForEach(timed) { item in
                let past = (item.endDate ?? item.date) <= now
                Button { model.open(item) } label: {
                    HStack(spacing: 10) {
                        Text(item.continuation ? "…" : (item.eventStartDate ?? item.date).formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(GalleryPalette.muted)
                            .frame(width: 66, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(GalleryPalette.ink).lineLimit(1)
                            if let detail = item.agendaDetail { Text(detail).font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(past ? 0.45 : 1)
            }
        }
    }
    private func chip(_ item: AgendaItem) -> some View {
        Button { model.open(item) } label: {
            HStack(spacing: 5) {
                Circle().fill(item.color).frame(width: 7, height: 7)
                Text(item.title).font(.caption.weight(.medium)).foregroundStyle(GalleryPalette.ink).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(item.color.opacity(0.15), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var tasks: some View {
        let total = overdue.count + dueToday.count + undated.count
        return card("TASKS", trailing: total == 0 ? nil : "\(total) left") {
            if !model.reminderAccess {
                Text("Connect Reminders to see tasks").font(.subheadline).foregroundStyle(GalleryPalette.muted)
            } else if total == 0 {
                Label("All caught up", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(GalleryPalette.muted)
            }
            taskGroup("Overdue", overdue.map(Self.item), tint: .red)
            taskGroup("Today", dueToday, tint: GalleryPalette.muted)
            taskGroup("Anytime", undated.map(Self.item), tint: GalleryPalette.muted)
        }
    }
    @ViewBuilder private func taskGroup(_ title: String, _ rows: [AgendaItem], tint: Color) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased()).font(.system(.caption2, design: .monospaced).weight(.semibold)).foregroundStyle(tint).padding(.top, 2)
            ForEach(rows) { taskRow($0) }
        }
    }
    private func taskRow(_ item: AgendaItem) -> some View {
        HStack(spacing: 10) {
            Button { if let reminder = model.reminder(withID: item.id) { model.toggle(reminder) } } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(item.color).frame(width: 28, height: 32)
            }.buttonStyle(.borderless).accessibilityLabel("Complete \(item.title)")
            Button { model.open(item) } label: {
                HStack(spacing: 6) {
                    Text(item.title).font(.subheadline).foregroundStyle(GalleryPalette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if !item.allDay { Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(GalleryPalette.muted) }
                    Text(item.source).font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .contextMenu {
            if let reminder = model.reminder(withID: item.id) { SnoozeButtons(model: model, reminder: reminder) }
        }
    }
    static func item(_ reminder: EKReminder) -> AgendaItem {
        AgendaItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", date: ReminderDates.due(reminder) ?? .now,
                   allDay: true, reminder: true, source: reminder.calendarTitle, color: reminder.calendarColor, notes: reminder.notes)
    }
}
