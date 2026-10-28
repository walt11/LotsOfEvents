import SwiftUI
import WidgetKit

/// Keeps the widget theme, custom colors, and look saved the moment they change, so previews built
/// in the same update read the new values.
@MainActor
final class WidgetStyleStore: ObservableObject {
    @Published var themeID = AgendaTheme.selected.rawValue {
        didSet { Preferences.defaults.set(themeID, forKey: "widgetTheme"); reload() }
    }
    /// Editing custom colors switches widgets to the Custom theme, as the old editor did.
    @Published var custom = CustomWidgetStyle.saved {
        didSet {
            custom.save()
            if themeID != AgendaTheme.custom.rawValue { themeID = AgendaTheme.custom.rawValue }
            reload()
        }
    }
    @Published var look = WidgetLook.saved {
        didSet { look.save(); reload() }
    }
    var theme: AgendaTheme { AgendaTheme(rawValue: themeID) ?? .matchApp }
    private var pending: Task<Void, Never>?
    /// Color pickers change continuously, so wait for a pause before asking widgets to redraw.
    private func reload() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { WidgetReloader.schedule() }
        }
    }
}

/// The widgets the editor can preview, each with the sizes it comes in.
enum PreviewWidget: String, CaseIterable, Identifiable {
    case upcoming, threeDay, split, next, five, month, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .upcoming: "Upcoming Agenda"
        case .threeDay: "Three-Day Agenda"
        case .split: DashboardKind.split.title
        case .next: DashboardKind.next.title
        case .five: DashboardKind.five.title
        case .month: DashboardKind.month.title
        case .focus: DashboardKind.focus.title
        }
    }
    var families: [WidgetFamily] {
        switch self {
        case .upcoming, .threeDay, .split: [.systemSmall, .systemMedium, .systemLarge]
        default: [.systemSmall]
        }
    }
    var dashboardKind: DashboardKind? {
        switch self {
        case .split: .split
        case .next: .next
        case .five: .five
        case .month: .month
        case .focus: .focus
        default: nil
        }
    }
}

extension WidgetFamily {
    /// Home Screen widget sizes on a 6.3-inch iPhone, in points.
    var previewSize: CGSize {
        switch self {
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        default: CGSize(width: 170, height: 170)
        }
    }
    var previewTitle: String {
        switch self {
        case .systemMedium: "Medium"
        case .systemLarge: "Large"
        default: "Small"
        }
    }
}

/// One place to style every widget, with a live preview of the real widget designs.
struct WidgetEditorView: View {
    @AppAccent private var accent
    @StateObject private var store = WidgetStyleStore()
    @State private var widget = PreviewWidget.threeDay
    @State private var family = WidgetFamily.systemMedium
    @State private var previewScheme = AppTheme.current.scheme
    @State private var agendaEntry: AgendaEntry?
    @State private var threeDayEntry: AgendaEntry?
    @State private var dashboardEntries: [DashboardKind: DashboardEntry] = [:]
    @State private var confirmingReset = false

    var body: some View {
        // The preview stays put above the controls so every change can be seen as it's made.
        VStack(spacing: 0) {
            preview.padding(.horizontal).padding(.bottom, 10)
            Divider()
            ScrollView { controls }
        }
        .background(GalleryPalette.paper)
        .navigationTitle("Widget Editor").navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .task { await loadEntries() }
        .onChange(of: widget) { _, widget in
            if !widget.families.contains(family) { family = widget.families[0] }
        }
        .confirmationDialog("Reset widget style?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                store.look = WidgetLook()
                store.custom = CustomWidgetStyle()
                store.themeID = AgendaTheme.matchApp.rawValue
            }
        } message: { Text("Widgets go back to Match App Theme with the standard text, layout, and custom colors.") }
    }
    private var controls: some View {
            VStack(alignment: .leading, spacing: 18) {
                section("Theme") { themeChips }
                section("Custom Colors") { colorControls }
                section("Text") { textControls }
                section("Layout") { layoutControls }
                section("Show") { visibilityControls }
                Button("Reset Widget Style", role: .destructive) { confirmingReset = true }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 16))
                Text("Changes apply to every LotsOfEvents widget. Colors apply to widgets using the Custom theme; editing them switches widgets to Custom. Each widget can still choose its own theme and accent in Edit Widget.")
                    .font(.footnote).foregroundStyle(GalleryPalette.muted).padding(.horizontal, 4)
            }
            .padding(.horizontal).padding(.vertical, 16)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("Widget", selection: $widget) {
                    ForEach(PreviewWidget.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(widget.title).font(.headline)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                }.foregroundStyle(GalleryPalette.ink)
            }
            .accessibilityLabel("Previewed widget, \(widget.title)")
            GeometryReader { geometry in
                let size = family.previewSize
                let scale = previewScale(size, width: geometry.size.width)
                renderedWidget
                    .frame(width: size.width, height: size.height)
                    .background { store.theme.backgroundView(previewScheme) }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .containerShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .environment(\.colorScheme, previewScheme)
                    // Widget buttons would really complete reminders and change pages, so the preview is look-only.
                    .allowsHitTesting(false)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: size.height * scale)
                    // Theme colors and the look are read when widget views are built, so rebuild on any change.
                    .id(previewKey)
            }
            .frame(height: family.previewSize.height * previewScale(family.previewSize, width: UIScreen.main.bounds.width - 32))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(wallpaper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the \(widget.title) widget, \(family.previewTitle.lowercased()) size")
            HStack(spacing: 10) {
                if widget.families.count > 1 {
                    Picker("Size", selection: $family) {
                        ForEach(widget.families, id: \.self) { Text($0.previewTitle).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Picker("Home Screen appearance", selection: $previewScheme) {
                    Image(systemName: "sun.max").tag(ColorScheme.light).accessibilityLabel("Light")
                    Image(systemName: "moon").tag(ColorScheme.dark).accessibilityLabel("Dark")
                }.pickerStyle(.segmented).frame(width: 96)
            }
        }
    }
    /// Fits the widget in the width, and keeps a large widget short enough to leave room for the controls.
    private func previewScale(_ size: CGSize, width: CGFloat) -> CGFloat {
        min(1, (width - 32) / size.width, 260 / size.height)
    }
    private var previewKey: String {
        "\(store.themeID)-\(store.custom.hashValue)-\(store.look.hashValue)-\(previewScheme)-\(widget.rawValue)-\(family)"
    }
    /// A soft Home Screen backdrop that follows the light or dark preview.
    private var wallpaper: LinearGradient {
        previewScheme == .dark
            ? LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.24), Color(red: 0.05, green: 0.30, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.72, green: 0.84, blue: 0.95), Color(red: 0.80, green: 0.93, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    @ViewBuilder private var renderedWidget: some View {
        let theme = store.theme
        switch widget {
        case .upcoming:
            AgendaWidgetView(entry: themed(agendaEntry ?? WidgetPreviewData.agenda(threeDay: false), theme))
        case .threeDay:
            ThreeDayAgendaView(entry: themed(threeDayEntry ?? WidgetPreviewData.agenda(threeDay: true), theme))
        default:
            let kind = widget.dashboardKind!
            DashboardView(entry: dashboardEntry(kind, theme), kind: kind, previewFamily: family)
        }
    }
    private func dashboardEntry(_ kind: DashboardKind, _ theme: AgendaTheme) -> DashboardEntry {
        var entry = dashboardEntries[kind] ?? WidgetPreviewData.dashboard(kind)
        entry.theme = theme
        return entry
    }
    private func themed(_ entry: AgendaEntry, _ theme: AgendaTheme) -> AgendaEntry {
        var entry = entry
        entry.theme = theme
        return entry
    }
    /// Real calendar data when it's connected and has something to show; otherwise sample items.
    private func loadEntries() async {
        let agenda = await AgendaProvider().entry(theme: .app, sources: nil)
        if !agenda.items.isEmpty { agendaEntry = agenda }
        let threeDay = await AgendaProvider(threeDay: true).entry(theme: .app, sources: nil, tasks: true)
        if !threeDay.items.isEmpty || !threeDay.tasks.isEmpty { threeDayEntry = threeDay }
        for kind in [DashboardKind.split, .next, .five, .month, .focus] {
            let entry = await DashboardProvider(kind: kind).load(theme: .app, sources: nil, days: kind == .split ? EventsTasksProvider.upcomingDays : 1)
            if !entry.items.isEmpty || !entry.tasks.isEmpty { dashboardEntries[kind] = entry }
        }
    }

    // MARK: Controls

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.footnote).foregroundStyle(GalleryPalette.muted).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private var divider: some View { Divider().padding(.leading, 12) }

    private var themeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(AgendaTheme.allCases) { option in
                    let selected = store.themeID == option.rawValue
                    Button { store.themeID = option.rawValue } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                option.backgroundView(previewScheme)
                                Text("Aa").font(.system(size: 17, weight: .semibold)).foregroundStyle(option.text(previewScheme))
                            }
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .containerShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .environment(\.colorScheme, previewScheme)
                            .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(selected ? accent : .clear, lineWidth: 2.5).padding(-4) }
                            Text(option == .matchApp ? "Match App" : option.title).font(.caption2).foregroundStyle(selected ? GalleryPalette.ink : GalleryPalette.muted).lineLimit(1)
                        }.frame(width: 70)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) theme")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.vertical, 14)
        }
    }

    private func colorBinding(_ path: WritableKeyPath<CustomWidgetStyle, StoredColor>) -> Binding<Color> {
        Binding(get: { store.custom[keyPath: path].color }, set: { store.custom[keyPath: path] = StoredColor($0) })
    }
    /// A color that's automatic until turned on, as an on/off switch with a picker below it.
    @ViewBuilder private func optionalColor(_ title: String, _ path: WritableKeyPath<CustomWidgetStyle, StoredColor?>, fallback: @escaping () -> Color, help: String) -> some View {
        Toggle(isOn: Binding(get: { store.custom[keyPath: path] != nil }, set: { store.custom[keyPath: path] = $0 ? StoredColor(fallback()) : nil })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(GalleryPalette.muted)
            }
        }.padding(12)
        if store.custom[keyPath: path] != nil {
            divider
            ColorPicker("\(title) color", selection: Binding(get: { store.custom[keyPath: path]?.color ?? fallback() }, set: { store.custom[keyPath: path] = StoredColor($0) }), supportsOpacity: false)
                .padding(12)
        }
    }
    @ViewBuilder private var colorControls: some View {
        Picker("Fill", selection: $store.custom.fill) {
            ForEach(CustomWidgetStyle.Fill.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).padding(12)
        divider
        ColorPicker(store.custom.fill == .solid ? "Background" : "First color", selection: colorBinding(\.first), supportsOpacity: false).padding(12)
        if store.custom.fill == .gradient {
            divider
            ColorPicker("Second color", selection: colorBinding(\.second), supportsOpacity: false).padding(12)
            divider
            LabeledContent("Direction") {
                Picker("Direction", selection: $store.custom.direction) {
                    ForEach(CustomWidgetStyle.Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
        divider
        optionalColor("Text", \.textColor, fallback: { store.custom.text }, help: "Off picks black or white to suit the background.")
        divider
        optionalColor("Secondary text", \.secondaryColor, fallback: { store.custom.secondary }, help: "Times, labels, and notes.")
        divider
        optionalColor("Accent", \.accent, fallback: { accent }, help: "Selected days and Next Up. Off uses the app accent.")
        divider
        HStack {
            Text("Border")
            Slider(value: $store.custom.borderWidth, in: 0...6, step: 0.5)
            Text(store.custom.borderWidth == 0 ? "None" : "\(store.custom.borderWidth.formatted()) pt").font(.footnote).foregroundStyle(GalleryPalette.muted).frame(width: 52, alignment: .trailing)
        }.padding(12)
        divider
        // Picking a color with no border yet turns on a 2 pt border so the change is visible.
        ColorPicker("Border color", selection: Binding(get: { store.custom.borderColor.color }, set: {
            store.custom.borderColor = StoredColor($0)
            if store.custom.borderWidth == 0 { store.custom.borderWidth = 2 }
        }), supportsOpacity: true).padding(12)
    }
    @ViewBuilder private var textControls: some View {
        LabeledContent("Font") {
            Picker("Font", selection: $store.look.font) {
                ForEach(WidgetLook.FontStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden()
        }.padding(.horizontal, 12).padding(.vertical, 6)
        divider
        VStack(alignment: .leading, spacing: 8) {
            Text("Text size")
            Picker("Text size", selection: $store.look.textSize) {
                ForEach(WidgetLook.TextSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        }.padding(12)
    }
    @ViewBuilder private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Row spacing")
            Picker("Row spacing", selection: $store.look.density) {
                ForEach(WidgetLook.Density.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("Compact fits more rows; Roomy is easier to read and tap.").font(.caption).foregroundStyle(GalleryPalette.muted)
        }.padding(12)
    }
    @ViewBuilder private var visibilityControls: some View {
        Toggle("Times", isOn: $store.look.showTimes).padding(12)
        divider
        Toggle("Calendar color bars", isOn: $store.look.showColorBars).padding(12)
        divider
        Toggle(isOn: $store.look.showSectionLabels) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Section labels")
                Text("Overdue, Tasks, Anytime, and similar headings. Dates always show.").font(.caption).foregroundStyle(GalleryPalette.muted)
            }
        }.padding(12)
        divider
        Toggle("Add (+) button", isOn: $store.look.showAddButton).padding(12)
    }
}

/// Sample items for previews when calendars aren't connected or have nothing coming up.
enum WidgetPreviewData {
    private static func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: .now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
    private static func event(_ id: String, _ title: String, day: Int, hour: Int, minute: Int = 0, hours: Double = 1, color: Color, allDay: Bool = false) -> AgendaItem {
        let start = allDay ? at(day, 0) : at(day, hour, minute)
        return AgendaItem(id: id, title: title, date: start, allDay: allDay, reminder: false, source: "Sample", color: color,
                          eventStartDate: start, endDate: allDay ? at(day + 1, 0) : start.addingTimeInterval(hours * 3600))
    }
    static var items: [AgendaItem] {
        [event("s1", "Team stand-up", day: 0, hour: 9, minute: 30, hours: 0.5, color: .blue),
         event("s2", "Lunch with Sam", day: 0, hour: 12, minute: 30, color: .green),
         event("s3", "Design review", day: 0, hour: 15, color: .purple),
         event("s4", "Yoga", day: 0, hour: 18, color: .orange),
         event("s5", "Anniversary", day: 1, hour: 0, color: .pink, allDay: true),
         event("s6", "Dentist", day: 1, hour: 10, color: .teal),
         event("s7", "Book club", day: 1, hour: 19, minute: 30, color: .indigo),
         event("s8", "Flight to Denver", day: 2, hour: 8, minute: 15, hours: 2.5, color: .red),
         event("s9", "Dinner with Alex", day: 3, hour: 19, color: .green)]
    }
    static var tasks: [WidgetTask] {
        [WidgetTask(id: "t1", title: "Renew passport", due: at(-1, 0), timed: false, list: "Personal", color: .orange, writable: false, priority: 0, overdue: true),
         WidgetTask(id: "t2", title: "Call the plumber", due: at(0, 14), timed: true, list: "Home", color: .blue, writable: false, priority: 0),
         WidgetTask(id: "t3", title: "Send invoices", due: at(0, 0), timed: false, list: "Work", color: .purple, writable: false, priority: 0),
         WidgetTask(id: "t4", title: "Pick up dry cleaning", due: at(1, 0), timed: false, list: "Personal", color: .orange, writable: false, priority: 0),
         WidgetTask(id: "t5", title: "Plan weekend hike", due: nil, timed: false, list: "Personal", color: .green, writable: false, priority: 0)]
    }
    static func agenda(threeDay: Bool) -> AgendaEntry {
        var entry = AgendaEntry(date: .now, items: items, page: 0, connected: true, selectedDay: Calendar.current.startOfDay(for: .now), days: threeDay ? 3 : 5)
        if threeDay {
            entry.showTasks = true
            entry.tasks = tasks
            entry.hasLists = true
        }
        return entry
    }
    static func dashboard(_ kind: DashboardKind) -> DashboardEntry {
        DashboardEntry(date: .now, items: items, tasks: tasks, calendarAccess: true, reminderAccess: true, hasLists: true,
                       selectedDay: Calendar.current.startOfDay(for: .now), days: kind == .split ? EventsTasksProvider.upcomingDays : 1)
    }
}
