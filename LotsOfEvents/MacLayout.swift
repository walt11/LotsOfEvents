import SwiftUI
import EventKit

/// The Mac window, built from the same cards, chips, and colors as the iPhone app: a sidebar with today, a small month,
/// and calendar chips; the calendar in the middle as a wall of day cards; and "Up next" on the right with the next
/// event, tasks, and the chosen day.
struct MacLayout: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @AppStorage("macSidebar", store: Preferences.defaults) private var showSidebar = true
    @AppStorage("macInspector", store: Preferences.defaults) private var showInspector = true
    @AppStorage("macView", store: Preferences.defaults) private var viewID = MacView.month.rawValue
    private var view: MacView { MacView(rawValue: viewID) ?? .month }
    private var calendar: Calendar { .current }
    private var date: Date { model.calendarDate }

    var body: some View {
        GeometryReader { geometry in
            let panes = Panes(width: geometry.size.width, sidebar: showSidebar, inspector: showInspector)
            HStack(spacing: 0) {
                if panes.sidebar {
                    MacSidebar(model: model).frame(width: 248)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    header(panes).padding(.top, panes.sidebar ? 0 : 28)
                    ChipBar(options: MacView.allCases, selection: Binding(get: { view }, set: select)) { $0.title }
                    content
                }
                .frame(minWidth: 560)
                if panes.inspector {
                    MacUpNextPanel(model: model).frame(width: 290)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // The title bar is hidden, so the panes start at the top of the window instead of below an empty strip.
            .ignoresSafeArea(.container, edges: .top)
            .background(GalleryPalette.paper)
            .onAppear { if let mode = view.calendarMode { model.calendarMode = mode } }
            .background(MacWindowStyle())
            .onChange(of: viewID) { _, _ in
                if let mode = view.calendarMode { model.calendarMode = mode }
            }
            .onChange(of: model.calendarMode) { _, mode in
                if view.calendarMode != nil, let option = MacView.allCases.first(where: { $0.calendarMode == mode }) {
                    viewID = option.rawValue
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macCalendarCommand)) { note in
                guard let command = note.object as? String else { return }
                if let option = MacView(rawValue: command) { select(option) }
                else {
                    switch command {
                    case "newEvent": model.sheet = .newEvent(model.calendarCreationDate)
                    case "newReminder": model.sheet = .reminder(nil, model.activeReminderList)
                    case "quickAdd": model.sheet = .quickAdd(reminder: false)
                    case "settings": model.sheet = .settings
                    default: break
                    }
                }
            }
        }
    }

    // MARK: Header

    /// Which side panes fit: the sidebar from 900 points wide, both from 1200.
    private struct Panes {
        let width: CGFloat
        let sidebar: Bool
        let inspector: Bool
        var roomForBoth: Bool { width >= 1200 }
        var roomForOne: Bool { width >= 900 }
        init(width: CGFloat, sidebar wantsSidebar: Bool, inspector wantsInspector: Bool) {
            self.width = width
            sidebar = wantsSidebar && width >= 900
            inspector = wantsInspector && width >= (sidebar ? 1200 : 900)
        }
    }

    private func header(_ panes: Panes) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Showing a pane that doesn't fit beside the other makes room by hiding the other, so the buttons always respond.
            Button("Sidebar", systemImage: "sidebar.left") {
                withAnimation(.snappy) {
                    if panes.sidebar { showSidebar = false }
                    else { showSidebar = true; if !panes.roomForBoth { showInspector = false } }
                }
            }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(GalleryPalette.muted)
                .disabled(!panes.roomForOne)
                .help(panes.roomForOne ? "Show or hide the sidebar" : "Make the window wider to show the sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            VStack(alignment: .leading, spacing: 0) {
                Text(overline).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(GalleryPalette.ink).lineLimit(1)
            }
            .contentTransition(.numericText())
            .animation(.snappy, value: title)
            Spacer(minLength: 12)
            Button { model.sheet = .search } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search").lineLimit(1)
                    Text("⌘F").font(.caption.weight(.medium)).foregroundStyle(GalleryPalette.muted)
                }
                .font(.subheadline).foregroundStyle(GalleryPalette.muted)
                .padding(.horizontal, 12).frame(height: 32)
                .gallerySurface(radius: 16)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f")
            if view != .agenda && view != .reminders {
                HStack(spacing: 0) {
                    Button("Back", systemImage: "chevron.left") { shift(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Today") { model.calendarDate = .now }
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
                        .keyboardShortcut("t")
                    Button("Forward", systemImage: "chevron.right") { shift(1) }
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .padding(.horizontal, 8).frame(height: 32)
                .gallerySurface(radius: 16)
            }
            Button("Up next", systemImage: "sidebar.right") {
                withAnimation(.snappy) {
                    if panes.inspector { showInspector = false }
                    else { showInspector = true; if !panes.roomForBoth { showSidebar = false } }
                }
            }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(GalleryPalette.muted)
                .disabled(!panes.roomForOne)
                .help(panes.roomForOne ? "Show or hide Up next" : "Make the window wider to show Up next")
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
    }

    /// The small accent line above the title: the year, or what kind of range is shown.
    private var overline: String {
        switch view {
        case .year: return "Year"
        case .agenda: return "Coming up"
        case .reminders: return "Your lists"
        case .day: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.year())
        }
    }
    private var title: String {
        switch view {
        case .month: return date.formatted(.dateTime.month(.wide))
        case .year: return date.formatted(.dateTime.year())
        case .agenda: return "Agenda"
        case .reminders: return "Reminders"
        case .day: return date.formatted(.dateTime.month(.wide).day())
        case .week, .threeDay:
            let start = view == .week ? calendar.dateInterval(of: .weekOfYear, for: date)!.start : calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: view == .week ? 6 : 2, to: start)!
            return (start..<end).formatted(.interval.month(.abbreviated).day())
        }
    }

    @ViewBuilder private var content: some View {
        switch view {
        case .month: MacMonthView(model: model)
        case .agenda: AgendaView(model: model)
        case .reminders: RemindersHome(model: model)
        default: CalendarHome(model: model, embedded: true)
        }
    }

    private func select(_ option: MacView) {
        viewID = option.rawValue
        if let mode = option.calendarMode { model.calendarMode = mode }
    }
    private func shift(_ direction: Int) {
        let step: (Calendar.Component, Int) = switch view {
        case .day: (.day, 1)
        case .threeDay: (.day, 3)
        case .week: (.day, 7)
        case .month, .agenda, .reminders: (.month, 1)
        case .year: (.year, 1)
        }
        model.calendarDate = calendar.date(byAdding: step.0, value: step.1 * direction, to: date) ?? date
    }
}

/// The views the Mac window switches between, in chip order.
enum MacView: String, CaseIterable, Identifiable {
    case day, threeDay, week, month, year, agenda, reminders
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "Day"
        case .threeDay: return "3 Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .agenda: return "Agenda"
        case .reminders: return "Reminders"
        }
    }
    var calendarMode: CalendarDisplay? {
        switch self {
        case .day: return .day
        case .threeDay: return .threeDay
        case .week: return .week
        case .month: return .month
        case .year: return .year
        case .agenda, .reminders: return nil
        }
    }
}

// MARK: - Sidebar

/// Today at the top with New, a small month card, then calendars and lists as chips: filled when shown, outlined when hidden.
struct MacSidebar: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @ObservedObject private var weather = WeatherStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                todayCard
                MacMiniMonth(model: model).padding(10).gallerySurface(radius: 16)
                chips(title: "Calendars", sources: model.calendars, reminders: false, access: model.calendarAccess) {
                    Task { await model.request(.event) }
                }
                chips(title: "Lists", sources: model.lists, reminders: true, access: model.reminderAccess) {
                    Task { await model.request(.reminder) }
                }
                Button { model.sheet = .settings } label: {
                    Label("Settings", systemImage: "gearshape").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                }
                .buttonStyle(.plain).padding(.top, 4)
            }
            // Just below the window's close, minimize, and zoom buttons.
            .padding(.horizontal, 14).padding(.top, 36).padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .background(GalleryPalette.card.opacity(0.45))
        .overlay(alignment: .trailing) { Rectangle().fill(GalleryPalette.line).frame(width: 0.5) }
    }

    private var todayCard: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(context.date.formatted(.dateTime.weekday(.wide))).font(.title2.bold()).foregroundStyle(GalleryPalette.ink)
                        Text(context.date.formatted(.dateTime.month(.wide).day())).font(.subheadline).foregroundStyle(GalleryPalette.muted)
                    }
                    Spacer(minLength: 0)
                    if let forecast = weather.forecast(for: context.date) { WeatherSummary(forecast: forecast) }
                }
                Menu {
                    Button("New Event…", systemImage: "calendar.badge.plus") { model.sheet = .newEvent(model.calendarCreationDate) }
                    Button("New Reminder…", systemImage: "checklist") { model.sheet = .reminder(nil, model.activeReminderList) }
                    Button("Quick Add…", systemImage: "text.badge.plus") { model.sheet = .quickAdd(reminder: false) }
                } label: {
                    Label("New", systemImage: "plus").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(_accent.contrastingText)
                        .background(accent, in: Capsule())
                }
                .menuIndicator(.hidden).buttonStyle(.plain)
            }
            .padding(14).gallerySurface(radius: 16)
        }
    }

    @ViewBuilder private func chips(title: String, sources: [EKCalendar], reminders: Bool, access: Bool, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, trailing: access ? "\(sources.filter { Preferences.selected($0.calendarIdentifier, reminders: reminders) }.count) of \(sources.count)" : nil)
            if !access {
                Button("Connect \(reminders ? "Reminders" : "Calendar")", action: connect).buttonStyle(.bordered)
            }
            let accounts = Dictionary(grouping: sources, by: { $0.source.title }).sorted { $0.key < $1.key }
            ForEach(accounts, id: \.key) { account, entries in
                if accounts.count > 1 {
                    Text(account).font(.caption2.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                }
                FlowLayout(spacing: 6) {
                    ForEach(entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, id: \.calendarIdentifier) { source in
                        chip(source, reminders: reminders, all: sources)
                    }
                }
            }
        }
    }

    private func chip(_ source: EKCalendar, reminders: Bool, all: [EKCalendar]) -> some View {
        let shown = Preferences.selected(source.calendarIdentifier, reminders: reminders)
        let color = Color(cgColor: source.cgColor)
        return Button {
            Preferences.setSelected(source.calendarIdentifier, enabled: !shown, reminders: reminders, available: all.map(\.calendarIdentifier))
            model.objectWillChange.send()
            model.scheduleRefresh()
            WidgetReloader.schedule()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(shown ? color : .clear).overlay { Circle().strokeBorder(color, lineWidth: 1.5) }.frame(width: 8, height: 8)
                Text(source.title).font(.caption.weight(.medium)).lineLimit(1)
                    .foregroundStyle(shown ? GalleryPalette.ink : GalleryPalette.muted)
            }
            .padding(.horizontal, 9).frame(height: 24)
            .background(shown ? color.opacity(0.18) : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(shown ? color.opacity(0.35) : GalleryPalette.line, lineWidth: 0.75) }
        }
        .buttonStyle(.plain)
        .help(shown ? "Hide \(source.title)" : "Show \(source.title)")
        .accessibilityLabel(source.title)
        .accessibilityValue(shown ? "Shown" : "Hidden")
    }
}

/// Lays chips out in rows, wrapping to the next row when one won't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if x > 0 && x + itemWidth > width { x = 0; y += row + spacing; row = 0 }
            x += itemWidth + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, bounds.width)
            if x > bounds.minX && x + itemWidth > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: itemWidth, height: size.height))
            x += itemWidth + spacing
            row = max(row, size.height)
        }
    }
}

/// A small month for jumping around: the chosen day is filled, today is in the accent color, busy days get a dot.
struct MacMiniMonth: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @State private var month = Date.now
    private var calendar: Calendar { .current }
    var body: some View {
        let days = CalendarDates.monthDays(containing: month)
        let busy = busyDays(days)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold)).foregroundStyle(GalleryPalette.ink)
                Spacer()
                Button("Previous month", systemImage: "chevron.left") { step(-1) }
                Button("Next month", systemImage: "chevron.right") { step(1) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.caption2).foregroundStyle(GalleryPalette.muted)
                }
                ForEach(days, id: \.self) { day in cell(day, busy: busy.contains(calendar.startOfDay(for: day))) }
            }
        }
        .onAppear { month = model.calendarDate }
        .onChange(of: model.calendarDate) { _, date in
            if !calendar.isDate(date, equalTo: month, toGranularity: .month) { month = date }
        }
    }
    private func cell(_ day: Date, busy: Bool) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: model.calendarDate)
        let today = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        return Button { model.calendarDate = day } label: {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.day())).font(.caption.weight(today || selected ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(selected ? _accent.contrastingText : today ? accent : inMonth ? GalleryPalette.ink : GalleryPalette.muted.opacity(0.5))
                    .frame(width: 22, height: 20)
                    .background(selected ? accent : .clear, in: Circle())
                Circle().fill(busy && inMonth && !selected ? GalleryPalette.muted : .clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
    private func step(_ direction: Int) { month = calendar.date(byAdding: .month, value: direction, to: month) ?? month }
    private func busyDays(_ days: [Date]) -> Set<Date> {
        guard let first = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        _ = model.generation
        var result = Set<Date>()
        for event in model.events(in: DateInterval(start: first, end: end)) {
            var day = calendar.startOfDay(for: event.startDate)
            repeat {
                result.insert(day)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            } while day < event.endDate && result.count < 400
        }
        return result
    }
}

// MARK: - Month

/// The month as a wall of day cards. Each card lists its events (time first, after a calendar-colored bar; all-day
/// events as tinted tags) and reminders due that day. Click a card to choose the day, double-click to add an event,
/// right-click an event for more.
struct MacMonthView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @State private var events: [EKEvent] = []
    @State private var repeating: EKEvent?
    @AppStorage("showWeekNumbers", store: Preferences.defaults) private var weekNumbers = false
    private var calendar: Calendar { .current }
    private var date: Date { model.calendarDate }
    private var days: [Date] { CalendarDates.compactMonthDays(containing: date) }
    private let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: 6) {
            weekdayRow
            GeometryReader { proxy in
                let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
                let height = (proxy.size.height - gap * CGFloat(max(0, weeks.count - 1))) / CGFloat(max(1, weeks.count))
                VStack(spacing: gap) {
                    ForEach(weeks, id: \.first) { week in
                        HStack(spacing: gap) {
                            if weekNumbers {
                                Text("W\(calendar.component(.weekOfYear, from: week[0]))").font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(GalleryPalette.muted).frame(width: 26)
                                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
                            }
                            ForEach(week, id: \.self) { day in card(day, height: height) }
                        }
                        .frame(height: height)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 2)
        .onAppear(perform: reload)
        .onChange(of: model.calendarDate) { old, new in
            if !calendar.isDate(old, equalTo: new, toGranularity: .month) { reload() }
            model.calendarCreationDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: new) ?? new
        }
        .onChange(of: model.generation) { _, _ in reload() }
        .confirmationDialog("This is a repeating event.", isPresented: Binding(get: { repeating != nil }, set: { if !$0 { repeating = nil } }),
                            titleVisibility: .visible, presenting: repeating) { event in
            Button("Delete This Event Only", role: .destructive) { model.delete(event, span: .thisEvent) }
            Button("Delete All Future Events", role: .destructive) { model.delete(event, span: .futureEvents) }
        }
    }

    private var weekdayRow: some View {
        let symbols = calendar.standaloneWeekdaySymbols
        return HStack(spacing: gap) {
            if weekNumbers { Color.clear.frame(width: 26) }
            ForEach(0..<7, id: \.self) { index in
                let weekday = (index + calendar.firstWeekday - 1) % 7
                Text(symbols[weekday]).font(.caption.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            }
        }
    }

    private func card(_ day: Date, height: CGFloat) -> some View {
        let inMonth = calendar.isDate(day, equalTo: date, toGranularity: .month)
        let selected = calendar.isDate(day, inSameDayAs: date)
        let today = calendar.isDateInToday(day)
        let items = entries(on: day)
        // Room for the date row, then lines of about 17 points.
        let capacity = max(0, Int((height - 34) / 17))
        let shown = items.count > capacity ? max(0, capacity - 1) : items.count
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(day.formatted(.dateTime.day())).font(.subheadline.weight(today ? .bold : .semibold)).monospacedDigit()
                    .foregroundStyle(today ? _accent.contrastingText : inMonth ? GalleryPalette.ink : GalleryPalette.muted)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(today ? accent : .clear, in: Circle())
                if calendar.component(.day, from: day) == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated))).font(.caption.weight(.semibold)).foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                if let forecast = WeatherStore.shared.forecast(for: day) {
                    Image(systemName: forecast.symbol).symbolRenderingMode(.multicolor).font(.caption)
                }
            }
            .padding(.bottom, 3)
            ForEach(items.prefix(shown)) { entry in line(entry) }
            if items.count > shown {
                Button("+\(items.count - shown) more") { model.calendarDate = day; open(.day) }
                    .buttonStyle(.plain).font(.caption2.weight(.semibold)).foregroundStyle(accent)
                    .padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(inMonth ? GalleryPalette.card : GalleryPalette.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? accent : today ? accent.opacity(0.5) : GalleryPalette.line, lineWidth: selected ? 1.5 : 0.5)
        }
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) {
            model.sheet = .newEvent(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)
        }
        .onTapGesture { model.calendarDate = day }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    @ViewBuilder private func line(_ entry: MonthEntry) -> some View {
        switch entry.kind {
        case .event(let event):
            Group {
                if event.isAllDay {
                    Text(event.title ?? "Event").font(.caption.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(GalleryPalette.ink)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
                        .background(event.calendarColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(event.calendarColor).frame(width: 3, height: 12)
                        Text(Self.shortTime(event.startDate)).monospacedDigit().foregroundStyle(GalleryPalette.muted)
                        Text(event.title ?? "Event").lineLimit(1).foregroundStyle(GalleryPalette.ink)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .onTapGesture { model.sheet = .event(event) }
            .contextMenu {
                Button("Open", systemImage: "arrow.up.forward.app") { model.sheet = .event(event) }
                Button("Duplicate", systemImage: "plus.square.on.square") { model.sheet = .duplicate(event) }
                if let link = MeetingLink.url(for: event) {
                    Button("Join \(MeetingLink.service(link))", systemImage: "video") { UIApplication.shared.open(link) }
                }
                if event.isWritable && !event.isBirthday {
                    Divider()
                    Button("Delete Event", systemImage: "trash", role: .destructive) {
                        if event.hasRecurrenceRules { repeating = event } else { model.delete(event) }
                    }
                }
            }
            .help([event.title ?? "Event", event.timeRange, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        case .reminder(let reminder):
            HStack(spacing: 5) {
                Image(systemName: "circle").font(.system(size: 9, weight: .semibold)).foregroundStyle(reminder.calendarColor)
                Text(reminder.title ?? "Reminder").lineLimit(1).foregroundStyle(GalleryPalette.ink)
                Spacer(minLength: 0)
            }
            .font(.caption).frame(height: 16)
            .contentShape(Rectangle())
            .onTapGesture { model.sheet = .reminder(reminder, nil) }
            .contextMenu {
                Button("Complete", systemImage: "checkmark.circle") { model.toggle(reminder) }
                SnoozeButtons(model: model, reminder: reminder)
                Divider()
                Button("Delete Reminder", systemImage: "trash", role: .destructive) {
                    do { try model.delete(reminder) } catch { model.error = error.localizedDescription }
                }
            }
        }
    }

    /// "9", "9:30", "14:05" in 24-hour regions; "9a", "9:30p" otherwise, to leave room for titles.
    static func shortTime(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        let style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .narrow))
        return (minute == 0 ? date.formatted(style) : date.formatted(style.minute())).replacingOccurrences(of: " ", with: "")
    }

    private struct MonthEntry: Identifiable {
        enum Kind { case event(EKEvent), reminder(EKReminder) }
        let id: String
        let kind: Kind
    }

    private func entries(on day: Date) -> [MonthEntry] {
        let dayEvents = events.filter { CalendarDates.overlaps(start: $0.startDate, end: $0.endDate, day: day) }
            .sorted { if $0.isAllDay != $1.isAllDay { return $0.isAllDay }; return $0.startDate < $1.startDate }
            .map { MonthEntry(id: $0.occurrenceKey, kind: .event($0)) }
        let dayReminders = model.reminders.filter { reminder in
            guard !reminder.isCompleted, let calendarID = reminder.calendar?.calendarIdentifier,
                  Preferences.selected(calendarID, reminders: true), let due = ReminderDates.due(reminder) else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
        .map { MonthEntry(id: "reminder:\($0.calendarItemIdentifier)", kind: .reminder($0)) }
        return dayEvents + dayReminders
    }

    private func open(_ view: MacView) {
        Preferences.defaults.set(view.rawValue, forKey: "macView")
        if let mode = view.calendarMode { model.calendarMode = mode }
    }
    private func reload() {
        guard let first = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        events = model.events(in: DateInterval(start: first, end: end))
    }
}

// MARK: - Up next

/// The right-hand panel: the next event as a countdown card, tasks with today's progress and a field to add one,
/// and the chosen day's schedule.
struct MacUpNextPanel: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @State private var draft = ""
    @State private var destinationID = ""
    @FocusState private var adding: Bool
    private var calendar: Calendar { .current }
    var body: some View {
        VStack(spacing: 12) {
            nextEvent
            tasksCard.frame(maxHeight: .infinity)
            MacDaySummary(model: model).frame(height: 210).gallerySurface(radius: 16)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .background(GalleryPalette.card.opacity(0.45))
        .overlay(alignment: .leading) { Rectangle().fill(GalleryPalette.line).frame(width: 0.5) }
    }

    // MARK: Next event

    private var nextEvent: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let upcoming = model.events(in: DateInterval(start: now, duration: 7 * 86_400))
                .first { !$0.isAllDay && $0.endDate > now }
            let _ = model.generation
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Up next")
                if let event = upcoming {
                    Text(countdown(event, now: now)).font(.caption.weight(.bold)).textCase(.uppercase)
                        .foregroundStyle(event.calendarColor)
                    Text(event.title ?? "Event").font(.headline).foregroundStyle(GalleryPalette.ink).lineLimit(2)
                    Text(calendar.isDateInToday(event.startDate) ? event.timeRange
                         : "\(event.startDate.formatted(.dateTime.weekday(.wide))) · \(event.timeRange)")
                        .font(.caption).foregroundStyle(GalleryPalette.muted)
                    if let location = event.location, !location.isEmpty {
                        Label(location, systemImage: "mappin").font(.caption).foregroundStyle(GalleryPalette.muted).lineLimit(1)
                    }
                    HStack {
                        Button("Details") { model.sheet = .event(event) }.buttonStyle(.bordered)
                        if let link = MeetingLink.url(for: event) { JoinButton(url: link) }
                    }
                    .controlSize(.small).padding(.top, 2)
                } else {
                    Text("Nothing else this week").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16).fill(GalleryPalette.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [(upcoming?.calendarColor ?? accent).opacity(0.22), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(GalleryPalette.line, lineWidth: 0.5) }
        }
    }

    private func countdown(_ event: EKEvent, now: Date) -> String {
        if event.startDate <= now { return "Now · ends \(event.endDate.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(1, minutes)) min" }
        if calendar.isDateInToday(event.startDate) {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "In \(hours) hr" : "In \(hours) hr \(rest) min"
        }
        return calendar.isDateInTomorrow(event.startDate) ? "Tomorrow" : event.startDate.formatted(.dateTime.weekday(.wide))
    }

    // MARK: Tasks

    private var tasksCard: some View {
        let groups = grouped()
        let dueToday = groups.first { $0.title == "Today" }?.items.count ?? 0
        let overdue = groups.first { $0.title == "Overdue" }?.items.count ?? 0
        // A reminder whose list was deleted has no calendar, and EventKit's implicitly unwrapped one would crash.
        let done = model.completedToday.filter { $0.calendar.map { Preferences.selected($0.calendarIdentifier, reminders: true) } ?? false }.count
        let total = done + dueToday + overdue
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(GalleryPalette.line, lineWidth: 4)
                    Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                        .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                .animation(.snappy, value: done)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tasks").font(.headline).foregroundStyle(GalleryPalette.ink)
                    Text(total == 0 ? "Nothing due today" : "\(done) of \(total) done today").font(.caption).foregroundStyle(GalleryPalette.muted)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            if !model.reminderAccess {
                Button("Connect Reminders") { Task { await model.request(.reminder) } }.buttonStyle(.bordered)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(accent)
                    TextField("Add a task", text: $draft).textFieldStyle(.plain).font(.subheadline)
                        .focused($adding).onSubmit(add)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(GalleryPalette.paper, in: RoundedRectangle(cornerRadius: 8))
                Picker("Save to", selection: Binding(get: { destination?.calendarIdentifier ?? "" }, set: { destinationID = $0 })) {
                    ForEach(model.lists.filter(\.allowsContentModifications), id: \.calendarIdentifier) { list in
                        Text(list.title).tag(list.calendarIdentifier)
                    }
                }
                .font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if groups.allSatisfy({ $0.items.isEmpty }) {
                            Label("All caught up", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                                .padding(.top, 8)
                        }
                        ForEach(groups, id: \.title) { group in
                            if !group.items.isEmpty {
                                SectionHeader(title: group.title, trailing: "\(group.items.count)",
                                              tint: group.title == "Overdue" ? .red : GalleryPalette.muted)
                                    .padding(.top, 8)
                                ForEach(group.items, id: \.calendarItemIdentifier) { reminder in row(reminder) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gallerySurface(radius: 16)
    }

    private func row(_ reminder: EKReminder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggle(reminder) } label: {
                Image(systemName: "circle").foregroundStyle(reminder.calendarColor)
            }
            .buttonStyle(.plain).accessibilityLabel("Complete \(reminder.title ?? "reminder")")
            Button { model.sheet = .reminder(reminder, nil) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title ?? "Reminder").font(.subheadline).foregroundStyle(GalleryPalette.ink).lineLimit(2)
                    Text(detail(reminder)).font(.caption).foregroundStyle(GalleryPalette.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .contextMenu {
            SnoozeButtons(model: model, reminder: reminder)
            Divider()
            Button("Delete Reminder", systemImage: "trash", role: .destructive) {
                do { try model.delete(reminder) } catch { model.error = error.localizedDescription }
            }
        }
    }

    /// "Tomorrow, 9:00 AM · Work", or just the list for undated ones.
    private func detail(_ reminder: EKReminder) -> String {
        guard let due = ReminderDates.due(reminder) else { return reminder.calendarTitle }
        let day = calendar.isDateInToday(due) ? "Today" : calendar.isDateInTomorrow(due) ? "Tomorrow" : due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let when = reminder.dueDateComponents?.hour != nil ? "\(day), \(due.formatted(date: .omitted, time: .shortened))" : day
        return "\(when) · \(reminder.calendarTitle)"
    }

    private func grouped() -> [(title: String, items: [EKReminder])] {
        let open = model.reminders.filter { reminder in
            guard !reminder.isCompleted, let id = reminder.calendar?.calendarIdentifier else { return false }
            return Preferences.selected(id, reminders: true)
        }
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let week = calendar.date(byAdding: .day, value: 8, to: today)!
        func due(_ reminder: EKReminder) -> Date? { ReminderDates.due(reminder) }
        let sorted = open.sorted { (due($0) ?? .distantFuture) < (due($1) ?? .distantFuture) }
        return [
            ("Overdue", sorted.filter { due($0).map { $0 < today } ?? false }),
            ("Today", sorted.filter { due($0).map { $0 >= today && $0 < tomorrow } ?? false }),
            ("Next 7 days", sorted.filter { due($0).map { $0 >= tomorrow && $0 < week } ?? false }),
            ("Later", sorted.filter { due($0).map { $0 >= week } ?? false }),
            ("Anytime", open.filter { due($0) == nil }.sorted { ($0.title ?? "") < ($1.title ?? "") }),
        ]
    }

    private var destination: EKCalendar? {
        let writable = model.lists.filter(\.allowsContentModifications)
        return writable.first { $0.calendarIdentifier == destinationID }
            ?? writable.first { Preferences.selected($0.calendarIdentifier, reminders: true) }
            ?? writable.first { $0.calendarIdentifier == model.store.defaultCalendarForNewReminders()?.calendarIdentifier }
            ?? writable.first
    }

    /// Adds the typed task to the explicitly displayed destination list.
    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard let list = destination else {
            model.error = "Choose a default list for new reminders in the Reminders app first."
            return
        }
        let reminder = EKReminder(eventStore: model.store)
        reminder.title = title
        reminder.calendar = list
        do {
            try model.store.save(reminder, commit: true)
            Preferences.setSelected(list.calendarIdentifier, enabled: true, reminders: true, available: model.lists.map(\.calendarIdentifier))
            draft = ""
            adding = true
            model.scheduleRefresh()
        } catch { model.error = error.localizedDescription }
    }
}

/// The chosen day's events, at the bottom of Up next.
struct MacDaySummary: View {
    @ObservedObject var model: AgendaModel
    var body: some View {
        let day = Calendar.current.startOfDay(for: model.calendarDate)
        let events = model.events(in: CalendarDates.dayRange(day))
        let _ = model.generation
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                          trailing: events.isEmpty ? nil : "\(events.count) event\(events.count == 1 ? "" : "s")")
            if events.isEmpty {
                Text("A free day").font(.subheadline).foregroundStyle(GalleryPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(events, id: \.occurrenceKey) { event in
                            EventRow(color: event.calendarColor, title: event.title ?? "Event", detail: event.location,
                                     time: event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened),
                                     birthday: event.isBirthday, needsReply: event.needsReply,
                                     joinURL: event.endDate > .now ? MeetingLink.url(for: event) : nil) { model.sheet = .event(event) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
    }
}

/// Hides the redundant title and sets a minimum size; side panes collapse in narrower windows.
private struct MacWindowStyle: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { WindowObserver() }
    func updateUIView(_ uiView: UIView, context: Context) {}
    private final class WindowObserver: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            // The scene finishes connecting and opening its window a moment after the view joins it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let scene = self?.window?.windowScene else { return }
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
                let minimum = CGSize(width: 760, height: 600)
                scene.sizeRestrictions?.minimumSize = minimum
                // Expand only windows smaller than the supported compact layout.
                let frame = scene.effectiveGeometry.systemFrame
                if frame.width < minimum.width || frame.height < minimum.height {
                    let size = CGSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height))
                    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: size)))
                }
            }
            #endif
        }
    }
}


extension Notification.Name {
    static let macCalendarCommand = Notification.Name("LotsOfEvents.macCalendarCommand")
}

struct MacCalendarCommands: Commands {
    private func send(_ command: String) {
        NotificationCenter.default.post(name: .macCalendarCommand, object: command)
    }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event") { send("newEvent") }.keyboardShortcut("n")
            Button("New Reminder") { send("newReminder") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Quick Add") { send("quickAdd") }.keyboardShortcut("k")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { send("settings") }.keyboardShortcut(",")
        }
        CommandMenu("Navigate") {
            ForEach(Array(MacView.allCases.enumerated()), id: \.offset) { index, view in
                Button(view.title) { send(view.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
