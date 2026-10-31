import SwiftUI
import EventKit
import WidgetKit
import Contacts
import UniformTypeIdentifiers

struct SourcesView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Closes Settings when it's shown as a sheet, as on the Mac; the iPhone shows it as a tab instead.
    var done: (() -> Void)? = nil
    @AppStorage(AppTextSize.key, store: Preferences.defaults) private var textSizeID = AppTextSize.automatic.rawValue
    @AppStorage(AppDensity.key, store: Preferences.defaults) private var densityID = AppDensity.standard.rawValue
    @AppStorage(AppTheme.key, store: Preferences.defaults) private var appThemeID = AppTheme.graphite.rawValue
    private var appTheme: AppTheme { AppTheme(rawValue: appThemeID) ?? .graphite }
    @State private var days = Preferences.days
    @AppStorage("widgetTheme", store: Preferences.defaults) private var themeID = AgendaTheme.selected.rawValue
    private var theme: AgendaTheme { AgendaTheme(rawValue: themeID) ?? .gallery }
    // Default alerts; the same keys and defaults as AlertDefaults, in the shared App Group.
    @AppStorage("alertEvent", store: Preferences.defaults) private var eventAlert = EventAlertOption.minutes15.rawValue
    @AppStorage("alertReminder", store: Preferences.defaults) private var reminderAlert = ReminderAlertOption.atTime.rawValue
    @AppStorage("showWeekNumbers", store: Preferences.defaults) private var weekNumbers = false
    @AppStorage("secondTimeZone", store: Preferences.defaults) private var secondZoneID = ""
    @AppStorage(WeatherStore.key, store: Preferences.defaults) private var showWeather = false
    @AppStorage(BirthdayAges.key, store: Preferences.defaults) private var birthdayAges = false
    @AppStorage(TravelAlerts.key, store: Preferences.defaults) private var timeToLeave = false
    @AppStorage(NextEventActivity.key, store: Preferences.defaults) private var liveActivity = true
    @ObservedObject private var weather = WeatherStore.shared
    @AppStorage(ReminderNotifications.key, store: Preferences.defaults) private var reminderNotifications = true
    @AppStorage(ReminderNotifications.statusKey, store: Preferences.defaults) private var reminderNotificationStatus = ""
    @AppStorage("agendaShowEarlierItems", store: Preferences.defaults) private var agendaShowEarlierItems = false
    @State private var importing = false
    var category: SettingsCategory? = nil
    @State private var search = ""
    var body: some View {
        if category == nil { NavigationStack {
            settingsContent.searchable(text: $search, prompt: "Search settings")
                .navigationDestination(isPresented: $model.showingThemePicker) { appThemePicker }
        } }
        else { settingsContent }
    }
    private var settingsContent: some View {
            List {
                if category == nil {
                    ForEach(SettingsCategory.allCases.filter { $0.matches(search) }) { section in
                        NavigationLink {
                            SourcesView(model: model, category: section)
                        } label: {
                            settingsRow(section.title, symbol: section.symbol, color: accent, detail: summary(section))
                        }
                    }
                    if !SettingsCategory.allCases.contains(where: { $0.matches(search) }) {
                        ContentUnavailableView.search(text: search)
                    }
                }
                if category == .sources {
                ContactDatesSettings(model: model)
                Section {
                    NavigationLink { SourcePickerView(model: model, reminders: false) } label: {
                        settingsRow("Calendars", symbol: "calendar", color: .blue, detail: selectionSummary(reminders: false))
                    }
                    NavigationLink { SourcePickerView(model: model, reminders: true) } label: {
                        settingsRow("Reminder Lists", symbol: "checklist", color: .orange, detail: selectionSummary(reminders: true))
                    }
                    NavigationLink { CalendarSetsView(model: model) } label: {
                        settingsRow("Calendar Sets", symbol: "line.3.horizontal.decrease.circle", color: .indigo,
                                    detail: CalendarSet.saved.isEmpty ? "Groups like Work and Personal, with Focus filters" : "\(CalendarSet.saved.count) saved · switch with the filter button")
                    }
                    NavigationLink { TodayListsView(model: model) } label: {
                        settingsRow("Undated Tasks in Today", symbol: "sun.max", color: .yellow, detail: TodayListsView.summary(model))
                    }
                } header: { SectionHeader(title: "Calendars & Reminders") }
                .listRowBackground(GalleryPalette.card)

                }
                if category == .advanced {
                Section {
                    Toggle(isOn: $weekNumbers) { settingsRow("Week Numbers", symbol: "number", color: .gray, detail: "In Month view and beside dates") }
                    NavigationLink { TimeZonePicker(selection: $secondZoneID) } label: {
                        settingsRow("Second Time Zone", symbol: "globe", color: .cyan,
                                    detail: secondZoneID.isEmpty ? "Off" : TimeZonePicker.name(secondZoneID))
                    }
                    Toggle(isOn: $showWeather) { settingsRow("Weather", symbol: "cloud.sun", color: .orange, detail: "Forecast in Day, 3 Day, and Week views") }
                        .onChange(of: showWeather) { _, on in if on { Task { await weather.refresh(force: true) } } }
                    Toggle(isOn: $birthdayAges) {
                        settingsRow("Birthday Ages", symbol: "gift", color: .pink, detail: "From birth years in Contacts; needs the Birthdays calendar")
                    }
                        .onChange(of: birthdayAges) { _, on in
                            if on { Task { _ = try? await CNContactStore().requestAccess(for: .contacts); model.objectWillChange.send() } }
                        }
                } header: { SectionHeader(title: "Calendar") } footer: {
                    Group {
                        if showWeather, let problem = weather.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(GalleryPalette.warning)
                        } else if showWeather, let attribution = weather.attribution {
                            HStack(spacing: 6) {
                                AsyncImage(url: attribution.mark) { $0.resizable().scaledToFit() } placeholder: { Text(" Weather") }.frame(height: 12)
                                Link("Weather Data Sources", destination: attribution.legal)
                            }
                        }
                    }
                    .font(.footnote).foregroundStyle(GalleryPalette.muted)
                }.listRowBackground(GalleryPalette.card)

                }
                if category == .alerts {
                Section {
                    Toggle("LotsOfEvents Reminder Notifications", isOn: $reminderNotifications)
                        .onChange(of: reminderNotifications) { _, _ in model.scheduleRefresh() }
                    if !reminderNotificationStatus.isEmpty {
                        Text(reminderNotificationStatus).font(.footnote).foregroundStyle(GalleryPalette.warning)
                        Button("Open Notification Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } footer: {
                    Text("Send alerts for your selected reminder lists from LotsOfEvents. To avoid duplicate alerts, turn off Apple Reminders notifications in system Settings. Your reminder alarms stay unchanged. Open LotsOfEvents after changing reminders on another device to refresh upcoming alerts. Location alerts still use Apple Reminders.")
                }.listRowBackground(GalleryPalette.card)
                Section {
                    NavigationLink { DefaultAlertsView() } label: {
                        settingsRow("Default Alerts", symbol: "bell.badge", color: .red,
                                    detail: "Events: \(EventAlertOption(rawValue: eventAlert)?.title ?? "None") · Reminders: \(ReminderAlertOption(rawValue: reminderAlert)?.title ?? "None")")
                    }
                    Toggle(isOn: $timeToLeave) { settingsRow("Time to Leave", symbol: "car", color: .green, detail: "Alerts based on the drive to an event's location") }
                        .onChange(of: timeToLeave) { _, on in
                            Task {
                                if on { _ = await TravelAlerts.requestPermission() }
                                model.scheduleRefresh()
                            }
                        }
                    #if !targetEnvironment(macCatalyst)
                    Toggle(isOn: $liveActivity) { settingsRow("Next Event Countdown", symbol: "timer", color: .purple, detail: "Live Activity on the Lock Screen and in the Dynamic Island") }
                        .onChange(of: liveActivity) { _, _ in model.scheduleRefresh() }
                    #endif
                } header: { SectionHeader(title: "Alerts") }.listRowBackground(GalleryPalette.card)

                }
                if category == .appearance {
                Section {
                    Toggle("Show Earlier Items", isOn: $agendaShowEarlierItems)
                } header: { SectionHeader(title: "Agenda") } footer: {
                    Text("Show events that ended earlier today and tasks completed today. Unfinished overdue tasks stay visible either way.")
                }.listRowBackground(GalleryPalette.card)
                Section {
                    // Kept on the model so the gallery stays open when a new theme rebuilds the app's views.
                    Button { model.showingThemePicker = true } label: {
                        HStack {
                            settingsRow("App Theme", symbol: "circle.lefthalf.filled", color: GalleryPalette.accent, detail: appTheme.title)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ColorPicker(selection: $accent, supportsOpacity: false) {
                        settingsRow("Accent Color", symbol: "eyedropper", color: accent,
                                    detail: _accent.isCustom ? "Custom color, replacing the theme's" : "\(appTheme.title) theme color")
                    }
                    if _accent.isCustom {
                        Button("Use \(appTheme.title) Theme Color") { _accent.reset() }
                    }
                    Picker(selection: $textSizeID) {
                        ForEach(AppTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        settingsRow("Text Size", symbol: "textformat.size", color: .teal, detail: "Automatic follows the system, starting a size larger")
                    }
                    Picker(selection: $densityID) {
                        ForEach(AppDensity.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        settingsRow("Row Spacing", symbol: "rectangle.compress.vertical", color: .mint, detail: "Space between list rows")
                    }
                    // The Mac window has a sidebar instead of tabs.
                    #if !targetEnvironment(macCatalyst)
                    NavigationLink { TabsSettingsView() } label: {
                        settingsRow("Tabs", symbol: "dock.rectangle", color: .gray, detail: "Order, and the tab the app opens to")
                    }
                    #endif
                } header: { SectionHeader(title: "Appearance") }.listRowBackground(GalleryPalette.card)

                }
                if category == .widgets {
                Section {
                    NavigationLink {
                        WidgetEditorView()
                    } label: {
                        settingsRow("Widget Editor", symbol: "paintpalette", color: .purple, detail: "\(theme.title) · colors, text, and layout")
                    }
                    Stepper(value: $days, in: 2...14) {
                        settingsRow("Days Ahead", symbol: "arrow.right", color: .blue, detail: "\(days) days in agenda widgets")
                    }.onChange(of: days) { _, value in
                        Preferences.days = value
                        Preferences.defaults.set(0, forKey: "page")
                        model.scheduleRefresh()
                        WidgetReloader.schedule()
                    }
                    NavigationLink { WidgetGuideView() } label: {
                        settingsRow("Widget Guide", symbol: "square.grid.2x2", color: .indigo, detail: "Adding, customizing, and Quick Add")
                    }
                } header: { SectionHeader(title: "Widgets") }.listRowBackground(GalleryPalette.card)

                }
                if category == .advanced {
                Section {
                    Button { importing = true } label: {
                        settingsRow("Import Calendar File", symbol: "square.and.arrow.down", color: .teal, detail: "Add the events in an .ics file")
                    }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.ics, .calendarEvent]) { result in
                        if case .success(let url) = result { model.importCalendarFile(url) }
                    }
                } header: { SectionHeader(title: "Import") } footer: {
                    Text("You can also share an .ics file to LotsOfEvents from Mail, Files, or another app.")
                        .font(.footnote).foregroundStyle(GalleryPalette.muted)
                }.listRowBackground(GalleryPalette.card)

                }
                if category == .advanced {
                Section {
                    LabeledContent("Version", value: Self.version)
                } header: { SectionHeader(title: "About") }.listRowBackground(GalleryPalette.card)
                }
                if category == nil {
                    Section {
                        Link(destination: URL(string: "https://filedn.eu/llU18sSCFuIjhnGu5KyT3q8/LotsOfEvents/index.html")!) {
                            Label("Support", systemImage: "questionmark.circle")
                        }
                        Link(destination: URL(string: "https://filedn.eu/llU18sSCFuIjhnGu5KyT3q8/LotsOfEvents/privacy.html")!) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                    }
                    .listRowBackground(GalleryPalette.card)
                    Section {
                        Text("© 2026 John Walter. All rights reserved.")
                            .font(.footnote)
                            .foregroundStyle(GalleryPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listRowBackground(GalleryPalette.card)
            .navigationTitle(category?.title ?? "Settings")
            .galleryTitle(category?.title ?? "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar {
                if let done {
                    // Escape closes it too.
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).keyboardShortcut(.cancelAction) }
                }
            }
            .tint(accent)
    }
    /// "1.0 (12)": the version and build, as App Store Connect and TestFlight show them.
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }
    private func settingsRow(_ title: String, symbol: String, color: Color, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(GalleryPalette.muted)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
    private func summary(_ section: SettingsCategory) -> String {
        switch section {
        case .appearance: return "\(appTheme.title) · \(AppDensity(rawValue: densityID)?.title ?? "Standard") spacing"
        case .sources: return model.calendarAccess ? "Calendars: \(selectionSummary(reminders: false)) · lists and sets" : selectionSummary(reminders: false)
        case .alerts: return "Events: \(EventAlertOption(rawValue: eventAlert)?.title ?? "None") · reminders and travel"
        case .widgets: return "\(theme.title) · \(days) days ahead"
        case .advanced: return "Calendar options, import, and app information"
        }
    }
    private func selectionSummary(reminders: Bool) -> String {
        let sources = reminders ? model.lists : model.calendars
        let access = reminders ? model.reminderAccess : model.calendarAccess
        if !access { return "Connect Apple \(reminders ? "Reminders" : "Calendar")" }
        return "\(sources.filter { Preferences.selected($0.calendarIdentifier, reminders: reminders) }.count) of \(sources.count) selected"
    }
    /// The app's own themes; each fixes light or dark, so the app no longer follows the device setting.
    private var appThemePicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(AppTheme.allCases) { option in
                    let c = option.colors
                    Button {
                        appThemeID = option.rawValue
                        // Picking a theme takes its accent too; a custom accent can be set again afterwards.
                        _accent.reset()
                        // The default accent comes from the theme, and widgets use it too.
                        WidgetReloader.schedule()
                        // Match the Home Screen icon. iOS confirms the change with its own short alert. Custom keeps the current icon.
                        if option != .custom, UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != option.iconName {
                            UIApplication.shared.setAlternateIconName(option.iconName)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Circle().fill(GalleryPalette.hex(c.accent)).frame(width: 10, height: 10)
                                RoundedRectangle(cornerRadius: 2).fill(GalleryPalette.hex(c.ink)).frame(width: 54, height: 5)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(0..<2, id: \.self) { row in
                                    HStack(spacing: 6) {
                                        Circle().strokeBorder(GalleryPalette.hex(c.accent), lineWidth: 1.5).frame(width: 10, height: 10)
                                        RoundedRectangle(cornerRadius: 2).fill(GalleryPalette.hex(row == 0 ? c.ink : c.muted)).frame(width: row == 0 ? 70 : 52, height: 4)
                                    }
                                }
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(GalleryPalette.hex(c.card), in: RoundedRectangle(cornerRadius: 8))
                            HStack {
                                Text(option.title).font(.subheadline.weight(.semibold)).foregroundStyle(GalleryPalette.hex(c.ink))
                                Spacer()
                                Image(systemName: appThemeID == option.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(GalleryPalette.hex(appThemeID == option.rawValue ? c.accent : c.muted))
                            }
                        }
                        .padding(12)
                        .background(GalleryPalette.hex(c.paper), in: RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(appThemeID == option.rawValue ? GalleryPalette.hex(c.accent) : GalleryPalette.line, lineWidth: appThemeID == option.rawValue ? 2.5 : 0.5) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) theme")
                    .accessibilityAddTraits(appThemeID == option.rawValue ? .isSelected : [])
                }
            }
            .padding()
            NavigationLink {
                CustomAppThemeEditor {
                    appThemeID = AppTheme.custom.rawValue
                    _accent.reset()
                    WidgetReloader.schedule()
                }
            } label: {
                Label("Customize Colors", systemImage: "paintbrush")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            Text("Themes set the app’s colors, accent, and whether it looks light or dark. Choosing a theme replaces a custom accent color. Widgets set to Match App Theme follow it too.")
                .font(.footnote).foregroundStyle(GalleryPalette.muted).padding(.horizontal).padding(.bottom)
        }
        .background(GalleryPalette.paper)
        .navigationTitle("App Theme").navigationBarTitleDisplayMode(.inline)
    }
}

/// Picks a second time zone for the timeline, with search.
struct TimeZonePicker: View {
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    static func name(_ id: String) -> String {
        let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
        return [city, TimeZone(identifier: id)?.abbreviation()].compactMap { $0 }.joined(separator: " · ")
    }
    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc") }
        return search.isEmpty ? all : all.filter { Self.name($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Button { selection = ""; dismiss() } label: {
                HStack { Text("Off").foregroundStyle(.primary); Spacer(); if selection.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(zones, id: \.self) { id in
                Button { selection = id; dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Self.name(id)).foregroundStyle(.primary)
                            Text(Date.now.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: id) ?? .current).hour().minute())).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == id { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "City or region")
        .navigationTitle("Second Time Zone").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
}

/// Turns calendars or reminder lists on and off for the app and widgets, grouped by account.
/// Opened from Settings and from the filter menu on Calendar and Agenda.
struct SourcePickerView: View {
    @ObservedObject var model: AgendaModel
    let reminders: Bool
    var body: some View {
        let sources = reminders ? model.lists : model.calendars
        let access = reminders ? model.reminderAccess : model.calendarAccess
        let accounts = Dictionary(grouping: sources, by: { $0.source.title }).sorted { $0.key < $1.key }
        List {
            if !access {
                Section {
                    Button("Connect Apple \(reminders ? "Reminders" : "Calendar")") { Task { await model.request(reminders ? .reminder : .event) } }
                }
            } else if sources.isEmpty { ContentUnavailableView("No \(reminders ? "lists" : "calendars") yet", systemImage: reminders ? "checklist" : "calendar") }
            ForEach(accounts, id: \.key) { account, entries in
                Section {
                    ForEach(entries, id: \.calendarIdentifier) { source in
                        Toggle(isOn: Binding(get: { Preferences.selected(source.calendarIdentifier, reminders: reminders) }, set: {
                            Preferences.setSelected(source.calendarIdentifier, enabled: $0, reminders: reminders, available: sources.map(\.calendarIdentifier))
                            model.objectWillChange.send()
                            model.scheduleRefresh()
                            WidgetReloader.schedule()
                        })) {
                            HStack(spacing: 12) {
                                Circle().fill(Color(cgColor: source.cgColor)).frame(width: 10, height: 10)
                                Text(source.title)
                            }
                        }
                    }
                } header: { SectionHeader(title: account) }
            }
            Section {
                Text(reminders ? "Selected lists appear in your agenda and widgets. Only incomplete reminders due within the displayed date range are included." : "Selected calendars appear in your agenda, calendar views, and widgets. Calendar sets save a selection to switch back to.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .listRowBackground(GalleryPalette.card)
        .navigationTitle(reminders ? "Reminder Lists" : "Calendars").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
}

/// How to add and customize widgets, worded for the device the app is running on.
struct WidgetGuideView: View {
    var body: some View {
        List {
            #if targetEnvironment(macCatalyst)
            Section("Add a Widget") {
                Label("Click the date and time in the menu bar to open Notification Center.", systemImage: "menubar.rectangle")
                Label("Click Edit Widgets at the bottom.", systemImage: "plus.circle")
                Label("Search for LotsOfEvents, choose a size, and drag it to the desktop or Notification Center.", systemImage: "square.grid.2x2")
            }
            Section("Customize a Widget") {
                Text("Control-click a widget and choose Edit to pick its calendars, reminder lists, theme, font, text size, and spacing.")
                Text("Widgets use the calendars and lists chosen in Settings unless you pick others. macOS decides how often widgets refresh.")
                    .foregroundStyle(.secondary)
            }
            Section("Quick Add") {
                Text("Click + on a widget to add an event or reminder.")
            }
            #else
            Section("Add a Widget") {
                Label("Touch and hold your Home Screen.", systemImage: "hand.tap")
                Label("Tap Edit, then Add Widget.", systemImage: "plus.circle")
                Label("Search for LotsOfEvents and choose a layout.", systemImage: "square.grid.2x2")
            }
            Section("Customize a Widget") {
                Text("Touch and hold a widget, then choose Edit Widget to pick its calendars, reminder lists, theme, font, text size, and spacing.")
                Text("Widgets use the calendars and lists chosen in Settings unless you pick others. iOS decides how often widgets refresh.")
                    .foregroundStyle(.secondary)
            }
            Section("Quick Add") {
                Text("Tap + on a widget to add an event or reminder. Add Event and Add Reminder controls are also available in Control Center.")
            }
            #endif
        }
        .listRowBackground(GalleryPalette.card)
        .navigationTitle("Widget Guide").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
}


enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, sources, alerts, widgets, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .sources: "Calendars & Lists"
        case .alerts: "Alerts"
        case .widgets: "Widgets"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .sources: "calendar"
        case .alerts: "bell"
        case .widgets: "square.grid.2x2"
        case .advanced: "slider.horizontal.3"
        }
    }
    var keywords: String {
        switch self {
        case .appearance: "theme accent color text size spacing density tabs order dark light agenda earlier previous past completed history"
        case .sources: "calendars reminders lists accounts sets focus undated tasks today contacts anniversaries birthdays dates"
        case .alerts: "notifications default alerts travel time to leave countdown live activity"
        case .widgets: "widgets editor colors text layout days ahead guide"
        case .advanced: "week numbers second time zone weather birthday ages contacts import ics version about"
        }
    }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { (title + " " + keywords).localizedStandardContains(String($0)) }
    }
}
