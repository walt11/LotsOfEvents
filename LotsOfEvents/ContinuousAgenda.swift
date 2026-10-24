import SwiftUI
import EventKit

struct AgendaDay: Identifiable {
    let date: Date
    let items: [AgendaItem]
    var id: Date { date }
}

@MainActor
final class ContinuousAgenda: ObservableObject {
    @Published private(set) var days: [AgendaDay] = []
    @Published private(set) var loading = false
    private var nextDate = Calendar.current.startOfDay(for: .now)
    private var revision = 0
    static let pageSize = 30

    static func page(items: [AgendaItem], start: Date, days: Int = pageSize, calendar: Calendar = .current) -> [AgendaDay] {
        let rows = WidgetAgendaLayout.byDay(items, start: start, days: days, calendar: calendar)
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return (0..<days).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start))!
            return AgendaDay(date: date, items: grouped[date] ?? [])
        }
    }
    func refresh(store: EKEventStore) async {
        revision += 1
        let token = revision
        loading = true
        let start = Calendar.current.startOfDay(for: .now)
        // Keep the loaded range after an edit or a source-selection change.
        let total = max(1, days.count / Self.pageSize) * Self.pageSize
        // One query for the whole loaded range; each query fetches every incomplete reminder.
        let items = await AgendaQuery.load(store: store, now: start, days: total)
        guard revision == token, !Task.isCancelled else { if revision == token { loading = false }; return }
        days = Self.page(items: items, start: start, days: total)
        nextDate = Calendar.current.date(byAdding: .day, value: total, to: start)!
        loading = false
    }
    func loadMore(store: EKEventStore) async {
        guard !loading, !days.isEmpty else { return }
        loading = true
        let token = revision
        let start = nextDate
        let items = await AgendaQuery.load(store: store, now: start, days: Self.pageSize)
        guard token == revision, !Task.isCancelled else { if token == revision { loading = false }; return }
        days += Self.page(items: items, start: start)
        nextDate = Calendar.current.date(byAdding: .day, value: Self.pageSize, to: start)!
        loading = false
    }
}

enum AgendaSection: Identifiable {
    case day(AgendaDay)
    /// A run of consecutive empty days, shown as one line.
    case empty(start: Date, end: Date)
    var id: Date {
        switch self {
        case .day(let day): return day.date
        case .empty(let start, _): return start
        }
    }
}

extension ContinuousAgenda {
    /// Keeps days with items (and today) as sections and folds runs of empty days together.
    static func sections(_ days: [AgendaDay], today: Date, calendar: Calendar = .current) -> [AgendaSection] {
        var result: [AgendaSection] = []
        var run: [Date] = []
        func flush() {
            if let first = run.first, let last = run.last { result.append(.empty(start: first, end: last)) }
            run = []
        }
        for day in days {
            if day.items.isEmpty && !calendar.isDate(day.date, inSameDayAs: today) { run.append(day.date) }
            else { flush(); result.append(.day(day)) }
        }
        flush()
        return result
    }
}
