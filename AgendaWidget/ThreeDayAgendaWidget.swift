import SwiftUI
import UIKit
import WidgetKit
import AppIntents

/// Optical centering for weekday-over-date tabs. Text line boxes leave room above the weekday's capitals
/// and below the digits for descenders they don't have, so a plainly centered stack looks high.
enum DayTabMetrics {
    static func offset(weekdaySize: CGFloat, weekdayWeight: UIFont.Weight, dateSize: CGFloat, dateWeight: UIFont.Weight) -> CGFloat {
        let weekday = UIFont.systemFont(ofSize: weekdaySize, weight: weekdayWeight)
        let date = UIFont.systemFont(ofSize: dateSize, weight: dateWeight)
        return (-date.descender - (weekday.ascender - weekday.capHeight)) / 2
    }
}

struct SelectWidgetDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Select agenda day"
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
    static let title: LocalizedStringResource = "Page selected day"
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
        AppIntentConfiguration(kind: "ThreeDayAgenda", intent: AgendaConfigurationIntent.self, provider: AgendaProvider(threeDay: true)) {
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
    private var accent: (color: Color, onColor: Color, custom: Bool) { entry.theme.widgetAccent(appRGB: entry.accentRGB) }
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
                                Text(day.formatted(.dateTime.day())).font(.system(size: 19, weight: .medium, design: entry.theme == .gallery ? .serif : .default))
                            }
                            .offset(y: DayTabMetrics.offset(weekdaySize: 11, weekdayWeight: .semibold, dateSize: 19, dateWeight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            // On a custom background the accent can vanish, so unselected days use the readable text color.
                            .foregroundStyle(selected ? accent.onColor : entry.theme == .custom && !accent.custom ? entry.theme.text(colorScheme) : accent.color)
                            .background(selected ? accent.color : .clear, in: RoundedRectangle(cornerRadius: 11))
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
                }
                // Quick Add, opened on the day selected in this widget.
                .overlay(alignment: .trailing) {
                    Link(destination: URL(string: "lotsofevents://quick-add?day=\(Int(entry.selectedDay.timeIntervalSince1970))")!) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 22)
                    }
                    .accessibilityLabel("Add to \(entry.selectedDay.formatted(.dateTime.weekday(.wide)))")
                }
                .font(.system(size: 10, weight: .bold)).buttonStyle(.plain)
                    .foregroundStyle(entry.theme.secondary(colorScheme)).frame(height: 14)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(12)
        .foregroundStyle(entry.theme.text(colorScheme))
        .containerBackground(for: .widget) { entry.theme.backgroundView(colorScheme) }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }
}
