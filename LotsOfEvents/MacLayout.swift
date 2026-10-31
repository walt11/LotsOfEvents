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
    @AppStorage("macSidebarWidth", store: Preferences.defaults) private var sidebarWidth = 224.0
    @AppStorage("macInspectorWidth", store: Preferences.defaults) private var inspectorWidth = 340.0
    private var view: MacView { MacView(rawValue: viewID) ?? .month }
    private var calendar: Calendar { .current }
    private var date: Date { model.calendarDate }

    var body: some View {
        GeometryReader { geometry in
            let panes = Panes(width: geometry.size.width, sidebar: showSidebar, inspector: showInspector, sidebarWidth: sidebarWidth, inspectorWidth: inspectorWidth)
            HStack(spacing: 0) {
                if panes.sidebar {
                    MacSidebar(selectedView: view, select: select, model: model).frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    MacPaneDivider(width: $sidebarWidth, limits: 200...max(200, min(320, geometry.size.width - 572 - (panes.inspector ? inspectorWidth : 0))), reversed: false)
                }
                VStack(spacing: 0) {
                    header(panes)
                    content
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                if panes.inspector {
                    MacPaneDivider(width: $inspectorWidth, limits: 300...max(300, min(480, geometry.size.width - 572 - (panes.sidebar ? sidebarWidth : 0))), reversed: true)
                    inspector.frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Respect the native title-bar safe area: rapid clicks on navigation controls
            // must not be interpreted as a title-bar double click that zooms the window.
            .background(GalleryPalette.paper)
            .onAppear { if let mode = view.calendarMode { model.calendarMode = mode } }
            .background(MacWindowStyle())
            .onChange(of: model.inspectorSelection?.id) { _, id in
                guard id != nil else { return }
                if panes.roomForOne {
                    showInspector = true
                    if !panes.roomForBoth { showSidebar = false }
                }
            }
            .sheet(item: Binding(get: { panes.roomForOne ? nil : model.inspectorSelection }, set: { model.inspectorSelection = $0 })) { _ in
                inspector.frame(minWidth: 460, minHeight: 500)
            }
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

    /// Saved pane widths determine when side panels collapse.
    private struct Panes {
        let width: CGFloat
        let sidebar: Bool
        let inspector: Bool
        let sidebarWidth: Double
        let inspectorWidth: Double
        var roomForBoth: Bool { width >= 572 + sidebarWidth + inspectorWidth }
        var roomForOne: Bool { width >= 566 + max(sidebarWidth, inspectorWidth) }
        init(width: CGFloat, sidebar wantsSidebar: Bool, inspector wantsInspector: Bool, sidebarWidth: Double, inspectorWidth: Double) {
            self.width = width; self.sidebarWidth = sidebarWidth; self.inspectorWidth = inspectorWidth
            sidebar = wantsSidebar && width >= 566 + sidebarWidth
            inspector = wantsInspector && width >= 566 + inspectorWidth + (sidebar ? sidebarWidth + 6 : 0)
        }
    }

    private func header(_ panes: Panes) -> some View {
        HStack(spacing: 12) {
            Button("Sidebar", systemImage: "sidebar.left") {
                withAnimation(.snappy) {
                    if panes.sidebar { showSidebar = false }
                    else { showSidebar = true; if !panes.roomForBoth { showInspector = false } }
                }
            }.labelStyle(.iconOnly).disabled(!panes.roomForOne).keyboardShortcut("s", modifiers: [.command, .control])
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold()).foregroundStyle(GalleryPalette.ink).lineLimit(1)
                if !panes.sidebar {
                    Menu {
                        Button("Calendar") { select(MacView.allCases.first { $0.calendarMode == model.calendarMode } ?? .month) }
                        Button("Agenda") { select(.agenda) }
                        Button("Reminders") { select(.reminders) }
                    } label: { Label(view.calendarMode == nil ? view.title : "Calendar", systemImage: "chevron.down").font(.caption) }
                }
            }
            Spacer(minLength: 0)
            if view.calendarMode != nil {
                HStack(spacing: 10) {
                    Button("Previous", systemImage: "chevron.left") { shift(-1) }.labelStyle(.iconOnly).keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Today") { model.calendarDate = .now }.keyboardShortcut("t")
                    Button("Next", systemImage: "chevron.right") { shift(1) }.labelStyle(.iconOnly).keyboardShortcut(.rightArrow, modifiers: .command)
                }.font(.subheadline)
                Picker("View", selection: Binding(get: { view }, set: select)) {
                    ForEach(MacView.allCases.filter { $0.calendarMode != nil }) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden().fixedSize().accessibilityLabel("Calendar view")
            } else if view == .agenda {
                Button("Today") { model.agendaReturnToToday += 1 }.keyboardShortcut("t")
            }
            if view != .reminders { CalendarSetsMenu(model: model) }
            Button("Search", systemImage: "magnifyingglass") { model.sheet = .search }.labelStyle(.iconOnly).keyboardShortcut("f")
            Button("Quick Add", systemImage: "plus") { model.sheet = .quickAdd(reminder: view == .reminders) }
                .labelStyle(.iconOnly).font(.headline).foregroundStyle(accent).help("Quick Add (⌘K)")
            Button("Inspector", systemImage: "sidebar.right") {
                withAnimation(.snappy) {
                    if panes.inspector { showInspector = false }
                    else { showInspector = true; if !panes.roomForBoth { showSidebar = false } }
                }
            }.labelStyle(.iconOnly).disabled(!panes.roomForOne).keyboardShortcut("i", modifiers: [.command, .option])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(minHeight: 58)
        .overlay(alignment: .bottom) { Rectangle().fill(GalleryPalette.line).frame(height: 0.5) }
    }

    @ViewBuilder private var inspector: some View {
        switch model.inspectorSelection {
        case .event(let event): MacEventDetails(model: model, event: event, embedded: true).id(event.occurrenceKey)
        case .reminder(let reminder?, _): MacReminderInspector(model: model, reminder: reminder).id(reminder.calendarItemIdentifier)
        default: MacUpNextPanel(model: model)
        }
    }

    private var title: String {
        switch view {
        case .month: return date.formatted(.dateTime.month(.wide).year())
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
        case .agenda: AgendaView(model: model, embedded: true)
        case .reminders: RemindersHome(model: model, embedded: true)
        default: CalendarHome(model: model, embedded: true)
        }
    }

    private func select(_ option: MacView) {
        if option != view { model.inspectorSelection = nil }
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
    @State private var orderingLists = false
    let selectedView: MacView
    let select: (MacView) -> Void
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 2) {
                    destination("Calendar", symbol: "calendar", selected: selectedView.calendarMode != nil) {
                        select(MacView.allCases.first { $0.calendarMode == model.calendarMode } ?? .month)
                    }
                    destination("Agenda", symbol: "list.bullet.rectangle", selected: selectedView == .agenda) { select(.agenda) }
                    destination("Reminders", symbol: "checklist", selected: selectedView == .reminders) { select(.reminders) }
                }
                Divider()
                MacMiniMonth(model: model).padding(10).gallerySurface(radius: 16)
                chips(title: "Calendars", sources: model.calendars, reminders: false, access: model.calendarAccess) {
                    Task { await model.request(.event) }
                }
                chips(title: "Lists", sources: model.lists, reminders: true, access: model.reminderAccess) {
                    Task { await model.request(.reminder) }
                }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        // The window safe area now reserves the native title bar above this sidebar.
        .background(GalleryPalette.card.opacity(0.45))
        .sheet(isPresented: $orderingLists) { ReminderListOrderView(model: model) }
        .overlay(alignment: .trailing) { Rectangle().fill(GalleryPalette.line).frame(width: 0.5) }
    }

    private func destination(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 36)
                .foregroundStyle(selected ? accent : GalleryPalette.ink)
                .background(selected ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func chips(title: String, sources: [EKCalendar], reminders: Bool, access: Bool, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, trailing: access ? "\(sources.filter { Preferences.selected($0.calendarIdentifier, reminders: reminders) }.count) of \(sources.count)" : nil)
            if !access {
                Button("Connect \(reminders ? "Reminders" : "Calendar")", action: connect).buttonStyle(.bordered)
            }
            if reminders {
                Button("Reorder Lists", systemImage: "arrow.up.arrow.down") { orderingLists = true }
                    .font(.caption).buttonStyle(.plain).disabled(sources.count < 2)
                FlowLayout(spacing: 6) {
                    ForEach(sources, id: \.calendarIdentifier) { source in
                        chip(source, reminders: true, all: sources)
                    }
                }
            } else {
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
    @ScaledMetric(relativeTo: .subheadline) private var eventRowHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) private var dateRowHeight: CGFloat = 30
    private let gap: CGFloat = 0

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
                Text(symbols[weekday]).font(.subheadline.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
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
        // Match capacity to the scaled text so larger fonts never overlap rows.
        let capacity = max(0, Int((height - dateRowHeight - 16) / (eventRowHeight + 1)))
        let shown = items.count > capacity ? max(0, capacity - 1) : items.count
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(day.formatted(.dateTime.day())).font(.headline.weight(today ? .bold : .semibold)).monospacedDigit()
                    .foregroundStyle(today ? _accent.contrastingText : inMonth ? GalleryPalette.ink : GalleryPalette.muted)
                    .frame(minWidth: dateRowHeight, minHeight: dateRowHeight)
                    .background(today ? accent : .clear, in: Circle())
                if calendar.component(.day, from: day) == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated))).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                if let forecast = WeatherStore.shared.forecast(for: day) {
                    Image(systemName: forecast.symbol).symbolRenderingMode(.multicolor).font(.subheadline)
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
        .background {
            ZStack {
                inMonth ? GalleryPalette.paper : GalleryPalette.card.opacity(0.35)
                // Follow the user's calendar locale rather than assuming Saturday/Sunday.
                if calendar.isDateInWeekend(day) { GalleryPalette.ink.opacity(0.055) }
                if selected { accent.opacity(0.07) }
            }
        }
        .overlay {
            Rectangle().strokeBorder(selected ? accent.opacity(0.7) : GalleryPalette.line, lineWidth: selected ? 1.5 : 0.5)
        }
        // Days from the months either side are quieter, but their events stay readable.
        .opacity(inMonth ? 1 : 0.75)
        .contentShape(Rectangle())
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
                    Text(event.title ?? "Event").font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(GalleryPalette.ink)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: eventRowHeight, alignment: .leading)
                        .background(event.calendarColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(event.calendarColor).frame(width: 3, height: 12)
                        Text(Self.shortTime(event.startDate)).monospacedDigit().foregroundStyle(GalleryPalette.muted)
                        Text(event.title ?? "Event").lineLimit(1).foregroundStyle(GalleryPalette.ink)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                }
            }
            .frame(height: eventRowHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.inspect(event) }
            .contextMenu {
                Button("Open", systemImage: "arrow.up.forward.app") { model.inspect(event) }
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
            .font(.subheadline).frame(height: eventRowHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.inspect(reminder) }
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

/// A compact event strip and a task-first inspector. Details expand inside the list so
/// opening a reminder doesn't replace the pane or discard its scroll position.
struct MacUpNextPanel: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    @State private var draft = ""
    @State private var destinationID = ""
    @State private var listID = ""
    @State private var filter = TaskFilter.today
    @State private var collapsed: Set<String> = ["Later", "Anytime"]
    @State private var expandedID: String?
    @State private var showDay = true
    @FocusState private var adding: Bool
    private var calendar: Calendar { .current }
    private enum TaskFilter: String, CaseIterable { case today = "Today", upcoming = "Upcoming", all = "All" }
    private var shownLists: [EKCalendar] { model.lists.filter { Preferences.selected($0.calendarIdentifier, reminders: true) } }
    private var writableLists: [EKCalendar] { model.lists.filter(\.allowsContentModifications) }

    var body: some View {
        VStack(spacing: 10) {
            nextEvent
            Divider()
            DisclosureGroup(isExpanded: $showDay) {
                MacDaySummary(model: model).frame(height: 170)
            } label: {
                Label("Day summary · \(model.calendarDate.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "calendar")
                    .font(.caption.weight(.medium)).foregroundStyle(GalleryPalette.muted)
            }
            Divider()
            tasksCard.frame(maxHeight: .infinity)
            if model.reminderAccess { composer }
        }
        .padding(12)
        .background(GalleryPalette.card.opacity(0.45))
        .overlay(alignment: .leading) { Rectangle().fill(GalleryPalette.line).frame(width: 0.5) }
        .onChange(of: model.generation) { _, _ in
            if !listID.isEmpty && !shownLists.contains(where: { $0.calendarIdentifier == listID }) { listID = "" }
            if let expandedID, !model.reminders.contains(where: { $0.calendarItemIdentifier == expandedID && !$0.isCompleted }) { self.expandedID = nil }
        }
    }

    private var nextEvent: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let end = calendar.date(byAdding: .day, value: 7, to: now)!
            let event = model.events(in: DateInterval(start: now, end: end)).first { !$0.isAllDay && $0.endDate > now }
            let _ = model.generation
            HStack(spacing: 8) {
                if let event {
                    RoundedRectangle(cornerRadius: 2).fill(event.calendarColor).frame(width: 3, height: 36)
                    Button { model.inspect(event) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("UP NEXT · \(countdown(event, now: now))").font(.caption2.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                            Text(event.title ?? "Event").font(.subheadline.weight(.medium)).foregroundStyle(GalleryPalette.ink).lineLimit(1)
                            Text(event.timeRange).font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Show event details")
                    if let link = MeetingLink.url(for: event) { JoinButton(url: link).controlSize(.small) }
                } else {
                    Label("No upcoming events this week", systemImage: "calendar").font(.caption).foregroundStyle(GalleryPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func countdown(_ event: EKEvent, now: Date) -> String {
        if event.startDate <= now { return "Now" }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(1, minutes)) min" }
        if calendar.isDate(event.startDate, inSameDayAs: now) { return "In \(minutes / 60) hr\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")" }
        return calendar.isDateInTomorrow(event.startDate) ? "Tomorrow" : event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var tasksCard: some View {
        let groups = grouped()
        let count = groups.reduce(0) { $0 + $1.items.count }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks").font(.headline).foregroundStyle(GalleryPalette.ink)
                Text("\(count)").font(.caption).foregroundStyle(GalleryPalette.muted)
                Spacer()
                Menu {
                    Picker("Lists", selection: $listID) {
                        Text("All selected lists").tag("")
                        ForEach(shownLists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                } label: {
                    Label(listID.isEmpty ? "Lists" : shownLists.first(where: { $0.calendarIdentifier == listID })?.title ?? "Lists", systemImage: "line.3.horizontal.decrease")
                        .font(.caption).lineLimit(1)
                }.help("Filter reminder lists").accessibilityLabel("Task list filter")
            }
            Picker("Tasks shown", selection: $filter) {
                ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if !model.reminderAccess {
                Button("Connect Reminders") { Task { await model.request(.reminder) } }.buttonStyle(.bordered)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if count == 0 {
                            Label(filter == .today ? "Nothing due today" : filter == .upcoming ? "No upcoming tasks" : "All caught up", systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(GalleryPalette.muted).padding(.vertical, 12)
                        }
                        ForEach(groups, id: \.title) { group in
                            if !group.items.isEmpty {
                                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(group.title) }, set: { expanded in
                                    if expanded { collapsed.remove(group.title) } else { collapsed.insert(group.title) }
                                })) {
                                    ForEach(group.items, id: \.calendarItemIdentifier) { row($0) }
                                } label: {
                                    HStack {
                                        Text(group.title).font(.caption.weight(.semibold))
                                        Spacer()
                                        Text("\(group.items.count)").font(.caption2).monospacedDigit()
                                    }.foregroundStyle(group.title == "Overdue" ? GalleryPalette.alert : GalleryPalette.muted)
                                }.padding(.top, 5)
                            }
                        }
                    }.padding(.bottom, 6)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func row(_ reminder: EKReminder) -> some View {
        let expanded = expandedID == reminder.calendarItemIdentifier
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Button { model.toggle(reminder) } label: {
                    Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(reminder.calendarColor).frame(width: 22, height: 25)
                }.buttonStyle(.plain).disabled(!reminder.isWritable).accessibilityLabel("Complete \(reminder.title ?? "reminder")")
                Button { withAnimation(.snappy) { expandedID = expanded ? nil : reminder.calendarItemIdentifier } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(reminder.title ?? "Reminder").font(.subheadline).foregroundStyle(GalleryPalette.ink).lineLimit(2)
                            Spacer(minLength: 0)
                            if let due = ReminderDates.due(reminder) {
                                Text(dueLabel(due, timed: reminder.dueDateComponents?.hour != nil)).font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1).fixedSize()
                            }
                        }
                        if listID.isEmpty { Text(reminder.calendarTitle).font(.caption2).foregroundStyle(GalleryPalette.muted).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(reminder.title ?? "reminder") details")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let due = ReminderDates.due(reminder) {
                        Label(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened), systemImage: "calendar").font(.caption)
                    }
                    if let notes = reminder.notes, !notes.isEmpty { Text(notes).font(.caption).textSelection(.enabled) }
                    if let url = reminder.url { Link(url.host() ?? url.absoluteString, destination: url).font(.caption).lineLimit(1) }
                    HStack {
                        Button("Edit", systemImage: "pencil") { model.sheet = .reminder(reminder, nil) }.disabled(!reminder.isWritable)
                        Menu("Snooze", systemImage: "clock") { SnoozeButtons(model: model, reminder: reminder) }.disabled(!reminder.isWritable)
                    }.buttonStyle(.bordered).controlSize(.small)
                }.foregroundStyle(GalleryPalette.muted).padding(.leading, 28).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if reminder.isWritable {
                SnoozeButtons(model: model, reminder: reminder)
                Divider()
                Button("Delete Reminder", systemImage: "trash", role: .destructive) {
                    do { try model.delete(reminder) } catch { model.error = error.localizedDescription }
                }
            }
        }
    }
    private func dueLabel(_ due: Date, timed: Bool) -> String {
        if calendar.isDateInToday(due) { return timed ? due.formatted(date: .omitted, time: .shortened) : "Today" }
        return calendar.isDateInTomorrow(due) ? "Tomorrow" : due.formatted(.dateTime.month(.abbreviated).day())
    }
    private func grouped() -> [(title: String, items: [EKReminder])] {
        let open = model.reminders.filter { reminder in
            guard !reminder.isCompleted, let id = reminder.calendar?.calendarIdentifier else { return false }
            return Preferences.selected(id, reminders: true) && (listID.isEmpty || listID == id)
        }
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let week = calendar.date(byAdding: .day, value: 8, to: today)!
        func due(_ reminder: EKReminder) -> Date? { ReminderDates.due(reminder) }
        let sorted = open.sorted {
            let lhs = due($0) ?? .distantFuture, rhs = due($1) ?? .distantFuture
            return lhs == rhs ? ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending : lhs < rhs
        }
        let groups: [(title: String, items: [EKReminder])] = [
            ("Overdue", sorted.filter { due($0).map { $0 < today } ?? false }),
            ("Today", sorted.filter { due($0).map { $0 >= today && $0 < tomorrow } ?? false }),
            ("Next 7 days", sorted.filter { due($0).map { $0 >= tomorrow && $0 < week } ?? false }),
            ("Later", sorted.filter { due($0).map { $0 >= week } ?? false }),
            ("Anytime", sorted.filter { due($0) == nil })
        ]
        return groups.filter { filter == .all || (filter == .today ? ["Overdue", "Today"].contains($0.title) : ["Next 7 days", "Later"].contains($0.title)) }
    }
    private var destination: EKCalendar? {
        writableLists.first { $0.calendarIdentifier == destinationID }
            ?? writableLists.first { $0.calendarIdentifier == listID }
            ?? writableLists.first { Preferences.selected($0.calendarIdentifier, reminders: true) }
            ?? writableLists.first { $0.calendarIdentifier == model.store.defaultCalendarForNewReminders()?.calendarIdentifier }
            ?? writableLists.first
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Add a task", text: $draft).textFieldStyle(.plain).font(.subheadline).focused($adding).onSubmit(add)
                    .disabled(destination == nil)
                Button(action: add) { Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(accent) }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || destination == nil)
                    .accessibilityLabel("Add task")
            }
            HStack {
                Text("Save to").font(.caption2).foregroundStyle(GalleryPalette.muted)
                Picker("Save to", selection: Binding(get: { destination?.calendarIdentifier ?? "" }, set: { destinationID = $0 })) {
                    if writableLists.isEmpty { Text("No writable lists").tag("") }
                    ForEach(writableLists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                }.labelsHidden().font(.caption).controlSize(.small)
                Spacer(minLength: 0)
            }
        }.padding(10).background(GalleryPalette.paper, in: RoundedRectangle(cornerRadius: 10))
    }
    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard let list = destination else { model.error = "Choose a writable reminder list first."; return }
        let reminder = EKReminder(eventStore: model.store)
        reminder.title = title; reminder.calendar = list
        do {
            try model.store.save(reminder, commit: true)
            Preferences.setSelected(list.calendarIdentifier, enabled: true, reminders: true, available: model.lists.map(\.calendarIdentifier))
            // A newly added undated task must remain visible even when Today was selected.
            filter = .all; listID = list.calendarIdentifier; collapsed.remove("Anytime")
            expandedID = reminder.calendarItemIdentifier
            draft = ""; adding = true
            model.scheduleRefresh()
        } catch { model.error = error.localizedDescription }
    }
}

/// The chosen day's events, above the task list in the inspector.
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
                                     joinURL: event.endDate > .now ? MeetingLink.url(for: event) : nil) { model.inspect(event) }
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


/// Drag a divider to resize a pane. Widths persist in the shared app preferences.
private struct MacPaneDivider: View {
    @Binding var width: Double
    let limits: ClosedRange<Double>
    let reversed: Bool
    @State private var startingWidth: Double?
    var body: some View {
        Rectangle().fill(GalleryPalette.line.opacity(0.5)).frame(width: 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if startingWidth == nil { startingWidth = width }
                width = min(limits.upperBound, max(limits.lowerBound, (startingWidth ?? width) + value.translation.width * (reversed ? -1 : 1)))
            }.onEnded { _ in startingWidth = nil })
            .accessibilityLabel(reversed ? "Inspector width" : "Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                width = min(limits.upperBound, max(limits.lowerBound, width + (direction == .increment ? 20 : -20)))
            }
            .help("Drag to resize")
    }
}

private struct MacReminderInspector: View {
    @ObservedObject var model: AgendaModel
    let reminder: EKReminder
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(reminder.title ?? "Reminder").font(.title2.bold()).foregroundStyle(GalleryPalette.ink)
                    // The list's color marks the dot; as text, pale colors like yellow would be hard to read.
                    Label { Text(reminder.calendarTitle).foregroundStyle(GalleryPalette.ink) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(reminder.calendarColor)
                    }.font(.subheadline)
                    if let due = ReminderDates.due(reminder) {
                        Label(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened), systemImage: "calendar")
                    }
                    if reminder.isWritable {
                        Button(reminder.isCompleted ? "Mark Incomplete" : "Complete", systemImage: reminder.isCompleted ? "arrow.uturn.backward" : "checkmark.circle") { model.toggle(reminder) }
                            .buttonStyle(.borderedProminent)
                        Menu("Snooze", systemImage: "clock") { SnoozeButtons(model: model, reminder: reminder) }
                    }
                    if let notes = reminder.notes, !notes.isEmpty { Text(notes).font(.callout).textSelection(.enabled) }
                    if let url = reminder.url { Link(url.host() ?? url.absoluteString, destination: url) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(GalleryPalette.paper).navigationTitle("Reminder").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model.inspectorSelection = nil } }
                ToolbarItem(placement: .primaryAction) { Button("Edit") { model.sheet = .reminder(reminder, nil) }.disabled(!reminder.isWritable) }
            }
        }
    }
}
