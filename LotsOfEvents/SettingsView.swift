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
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").font(.title).foregroundStyle(_accent.contrastingText)
                            .frame(width: 56, height: 56).background(accent, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make it yours").font(.title2.bold())
                            Text("Your schedule, your way.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear)
                Section {
                    NavigationLink { SourcePickerView(model: model, reminders: false) } label: {
                        settingsRow("Calendars", symbol: "calendar", color: .blue, detail: selectionSummary(reminders: false))
                    }
                    NavigationLink { SourcePickerView(model: model, reminders: true) } label: {
                        settingsRow("Reminder lists", symbol: "checklist", color: .orange, detail: selectionSummary(reminders: true))
                    }
                    NavigationLink { TodayListsView(model: model) } label: {
                        settingsRow("Undated tasks in Today", symbol: "sun.max", color: .yellow, detail: TodayListsView.summary(model))
                    }
                    NavigationLink { CalendarSetsView(model: model) } label: {
                        settingsRow("Calendar sets", symbol: "line.3.horizontal.decrease.circle", color: .indigo,
                                    detail: CalendarSet.saved.isEmpty ? "Groups like Work and Personal · Focus filters" : "\(CalendarSet.saved.count) saved · switch with the filter button")
                    }
                    Button { importing = true } label: {
                        settingsRow("Import calendar file", symbol: "square.and.arrow.down", color: .teal,
                                    detail: "Add events from an .ics file · or share one to LotsOfEvents")
                    }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.ics, .calendarEvent]) { result in
                        if case .success(let url) = result { model.importCalendarFile(url) }
                    }
                } header: { SectionHeader(title: "Calendars & Lists") }
                .listRowBackground(GalleryPalette.card)
                Section {
                    Toggle(isOn: $weekNumbers) { settingsRow("Week numbers", symbol: "number", color: .gray, detail: "In Month view and beside dates") }
                    NavigationLink { TimeZonePicker(selection: $secondZoneID) } label: {
                        settingsRow("Second time zone", symbol: "globe", color: .cyan,
                                    detail: secondZoneID.isEmpty ? "Off" : TimeZonePicker.name(secondZoneID))
                    }
                    Toggle(isOn: $showWeather) { settingsRow("Weather", symbol: "cloud.sun", color: .orange, detail: "Forecast in Day, 3 Day, and Week views") }
                        .onChange(of: showWeather) { _, on in if on { Task { await weather.refresh(force: true) } } }
                    Toggle(isOn: $birthdayAges) { settingsRow("Birthday ages", symbol: "gift", color: .pink, detail: "Uses birth years from Contacts") }
                        .onChange(of: birthdayAges) { _, on in
                            if on { Task { _ = try? await CNContactStore().requestAccess(for: .contacts); model.objectWillChange.send() } }
                        }
                } header: { SectionHeader(title: "Calendar View") } footer: {
                    if showWeather, let problem = weather.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if showWeather, let attribution = weather.attribution {
                        HStack(spacing: 6) {
                            AsyncImage(url: attribution.mark) { $0.resizable().scaledToFit() } placeholder: { Text(" Weather") }.frame(height: 12)
                            Link("Weather data sources", destination: attribution.legal)
                        }
                    } else {
                        Text("Birthdays come from the Birthdays calendar; turn it on under Calendars.")
                    }
                }.listRowBackground(GalleryPalette.card)
                Section {
                    // Kept on the model so the gallery stays open when a new theme rebuilds the app's views.
                    Button { model.showingThemePicker = true } label: {
                        HStack {
                            settingsRow("App theme", symbol: "circle.lefthalf.filled", color: GalleryPalette.accent, detail: appTheme.title)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ColorPicker(selection: $accent, supportsOpacity: false) {
                        settingsRow("App accent", symbol: "eyedropper", color: accent,
                                    detail: _accent.isCustom ? "Custom color · overrides the theme" : "\(appTheme.title) theme color")
                    }
                    if _accent.isCustom {
                        Button("Use \(appTheme.title) Theme Color") { _accent.reset() }
                    }
                    Picker(selection: $textSizeID) {
                        ForEach(AppTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        settingsRow("Text size", symbol: "textformat.size", color: .teal, detail: "Automatic follows your iPhone")
                    }
                    Picker(selection: $densityID) {
                        ForEach(AppDensity.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        settingsRow("Row spacing", symbol: "rectangle.compress.vertical", color: .mint, detail: "Space between list rows")
                    }
                    NavigationLink { TabsSettingsView() } label: {
                        settingsRow("Tabs", symbol: "dock.rectangle", color: .gray, detail: "Order and the tab the app opens to")
                    }
                } header: { SectionHeader(title: "Appearance") }.listRowBackground(GalleryPalette.card)
                Section {
                    NavigationLink { DefaultAlertsView() } label: {
                        settingsRow("Default alerts", symbol: "bell.badge", color: .red,
                                    detail: "Events: \(EventAlertOption(rawValue: eventAlert)?.title ?? "None") · Reminders: \(ReminderAlertOption(rawValue: reminderAlert)?.title ?? "None")")
                    }
                    Toggle(isOn: $timeToLeave) { settingsRow("Time to leave", symbol: "car", color: .green, detail: "Alerts based on the drive to an event's location") }
                        .onChange(of: timeToLeave) { _, on in
                            Task {
                                if on { _ = await TravelAlerts.requestPermission() }
                                model.scheduleRefresh()
                            }
                        }
                    #if !targetEnvironment(macCatalyst)
                    Toggle(isOn: $liveActivity) { settingsRow("Next event countdown", symbol: "timer", color: .purple, detail: "Live Activity on the Lock Screen and Dynamic Island") }
                        .onChange(of: liveActivity) { _, _ in model.scheduleRefresh() }
                    #endif
                } header: { SectionHeader(title: "Notifications") }.listRowBackground(GalleryPalette.card)
                Section {
                    NavigationLink {
                        WidgetEditorView()
                    } label: {
                        settingsRow("Widget editor", symbol: "paintpalette", color: .purple, detail: "\(theme.title) · colors, text, layout, preview")
                    }
                    Stepper(value: $days, in: 2...14) {
                        settingsRow("Days ahead", symbol: "arrow.right", color: accent, detail: "\(days) days in agenda widgets")
                    }.onChange(of: days) { _, value in
                        Preferences.days = value
                        Preferences.defaults.set(0, forKey: "page")
                        model.scheduleRefresh()
                        WidgetReloader.schedule()
                    }
                    NavigationLink {
                        List {
                            Section("Add a widget") {
                                Label("Touch and hold your Home Screen.", systemImage: "hand.tap")
                                Label("Choose Edit, then Add Widget.", systemImage: "plus.circle")
                                Label("Search for LotsOfEvents and choose a layout.", systemImage: "square.grid.2x2")
                            }
                            Section("Personalize each widget") {
                                Text("Touch and hold a widget, then choose Edit Widget to customize its calendars, reminder lists, and theme.")
                                Text("Widgets use your app selections unless you choose an override. iOS controls refresh timing.").foregroundStyle(.secondary)
                            }
                            Section("Quick Add") {
                                Text("Use + on a widget to add an event or reminder. Add Event and Add Reminder controls are also available in Control Center.")
                            }
                        }.navigationTitle("Widget guide").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
                    } label: { settingsRow("Widget guide", symbol: "square.grid.2x2", color: .indigo, detail: "Layouts, customization & Quick Add") }
                } header: { SectionHeader(title: "Widgets") }.listRowBackground(GalleryPalette.card)
            }
            .listRowBackground(GalleryPalette.card)
            .navigationDestination(isPresented: $model.showingThemePicker) { appThemePicker }
            .navigationTitle("Settings")
            .galleryTitle("Settings")
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
    }
    private func settingsRow(_ title: String, symbol: String, color: Color, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(color)
                .frame(width: 36, height: 36).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
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
            Text("Themes set the app’s colors, accent, and whether it looks light or dark. Choosing a theme replaces a custom App accent. Widgets set to Match App Theme follow it too.")
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
