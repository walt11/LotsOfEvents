import SwiftUI
import WidgetKit
import AppIntents

struct SelectWidgetDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Select agenda day"
    @Parameter(title: "Day") var timestamp: Double
    init() {}
    init(day: Date) { timestamp = day.timeIntervalSince1970 }
    func perform() async throws -> some IntentResult {
        Preferences.defaults.set(timestamp, forKey: "selectedWidgetDay")
        Preferences.defaults.set(0, forKey: "dayWidgetPage")
        WidgetCenter.shared.reloadTimelines(ofKind: "ThreeDayAgenda")
        return .result()
    }
}

struct PageDayWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Page selected day"
    @Parameter(title: "Page") var page: Int
    init() {}
    init(page: Int) { self.page = page }
    func perform() async throws -> some IntentResult {
        Preferences.defaults.set(max(0, page), forKey: "dayWidgetPage")
        WidgetCenter.shared.reloadTimelines(ofKind: "ThreeDayAgenda")
        return .result()
    }
}

struct ThreeDayAgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ThreeDayAgenda", provider: AgendaProvider(threeDay: true)) {
            ThreeDayAgendaView(entry: $0)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Three-Day Agenda")
        .description("Tap today, tomorrow, or the next day to see its events and selected reminders.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ThreeDayAgendaView: View {
    let entry: AgendaEntry
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark || entry.theme == .black }
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: entry.date)
        return (0..<3).map { Calendar.current.date(byAdding: .day, value: $0, to: today)! }
    }
    var body: some View {
        GeometryReader { geometry in
            let items = WidgetAgendaLayout.items(on: entry.selectedDay, from: entry.items)
            let pages = WidgetAgendaLayout.pages(items: items, height: max(0, geometry.size.height - 60), headings: false)
            let page = min(max(0, entry.dayPage), pages.count - 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        let selected = Calendar.current.isDate(day, inSameDayAs: entry.selectedDay)
                        Button(intent: SelectWidgetDayIntent(day: day)) {
                            VStack(spacing: 0) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 11, weight: .semibold))
                                Text(day.formatted(.dateTime.day())).font(.system(size: 19, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .foregroundStyle(selected ? (dark ? Color.black : Color.white) : Color.blue)
                            .background(selected ? (dark ? Color(white: 0.65) : Color(white: 0.25)) : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.bottom, 7)
                if !entry.connected {
                    Text("Open the app to connect calendars and reminders.").font(.caption).foregroundStyle(entry.theme.secondary(colorScheme))
                } else if items.isEmpty {
                    Text("No items for this day").font(.caption).foregroundStyle(entry.theme.secondary(colorScheme)).padding(.top, 4)
                } else {
                    ForEach(pages[page]) { item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 4)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if !item.allDay {
                                    Text(item.widgetTimeLabel).font(.system(size: 10)).lineLimit(1)
                                        .foregroundStyle(entry.theme.secondary(colorScheme)).frame(height: 12, alignment: .leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }.frame(height: item.allDay ? 14 : 26).padding(.bottom, 1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if pages.count > 1 {
                        Button(intent: PageDayWidgetIntent(page: (page + pages.count - 1) % pages.count)) {
                            Image(systemName: "chevron.left").frame(width: 24, height: 14)
                        }.accessibilityLabel("Previous page")
                        Text("\(page + 1)/\(pages.count)").font(.system(size: 9))
                        Button(intent: PageDayWidgetIntent(page: (page + 1) % pages.count)) {
                            Image(systemName: "chevron.right").frame(width: 24, height: 14)
                        }.accessibilityLabel("Next page")
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 10, weight: .bold)).buttonStyle(.plain)
                    .foregroundStyle(entry.theme.secondary(colorScheme)).frame(height: 14)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(12)
        .foregroundStyle(entry.theme.text(colorScheme))
        .containerBackground(for: .widget) { entry.theme.background(colorScheme) }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }
}
