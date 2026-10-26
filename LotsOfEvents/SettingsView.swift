import SwiftUI
import EventKit
import WidgetKit

struct SourcesView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// True when shown as the Settings tab rather than a sheet, so there is nothing to dismiss.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppTheme.key, store: Preferences.defaults) private var appThemeID = AppTheme.graphite.rawValue
    private var appTheme: AppTheme { AppTheme(rawValue: appThemeID) ?? .graphite }
    @State private var days = Preferences.days
    @AppStorage("widgetTheme", store: Preferences.defaults) private var themeID = AgendaTheme.selected.rawValue
    private var theme: AgendaTheme { AgendaTheme(rawValue: themeID) ?? .gallery }
    @State private var customStyle = CustomWidgetStyle.saved
    // Default alerts; the same keys and defaults as AlertDefaults, in the shared App Group.
    @AppStorage("alertEvent", store: Preferences.defaults) private var eventAlert = EventAlertOption.minutes15.rawValue
    @AppStorage("alertReminder", store: Preferences.defaults) private var reminderAlert = ReminderAlertOption.atTime.rawValue
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").font(.title).foregroundStyle(_accent.contrastingText)
                            .frame(width: 56, height: 56).background(accent, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make it yours").font(.system(.title2, design: .serif)).italic()
                            Text("Your schedule, your way.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear)
                Section("Your agenda") {
                    NavigationLink { sourcePicker(reminders: false) } label: {
                        settingsRow("Calendars", symbol: "calendar", color: .blue, detail: selectionSummary(reminders: false))
                    }
                    NavigationLink { sourcePicker(reminders: true) } label: {
                        settingsRow("Reminder lists", symbol: "checklist", color: .orange, detail: selectionSummary(reminders: true))
                    }
                    Stepper(value: $days, in: 2...14) {
                        settingsRow("Widget look ahead", symbol: "arrow.right", color: accent, detail: "\(days) days · agenda scrolls continuously")
                    }.onChange(of: days) { _, value in
                        Preferences.days = value
                        Preferences.defaults.set(0, forKey: "page")
                        model.scheduleRefresh()
                    }
                }.listRowBackground(GalleryPalette.card)
                Section("Appearance") {
                    // Kept on the model so the gallery stays open when a new theme rebuilds the app's views.
                    Button { model.showingThemePicker = true } label: {
                        HStack {
                            settingsRow("App theme", symbol: "circle.lefthalf.filled", color: GalleryPalette.accent, detail: appTheme.title)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ColorPicker(selection: $accent, supportsOpacity: false) {
                        settingsRow("App accent", symbol: "eyedropper", color: accent, detail: "Choose any color for buttons & selections")
                    }
                    Button("Reset app accent") { _accent.reset() }
                    NavigationLink {
                        themePicker
                    } label: {
                        settingsRow("Widget theme", symbol: "paintpalette", color: .purple, detail: theme.title)
                    }
                }.listRowBackground(GalleryPalette.card)
                Section("Notifications") {
                    NavigationLink { DefaultAlertsView() } label: {
                        settingsRow("Default alerts", symbol: "bell.badge", color: .red,
                                    detail: "Events: \(EventAlertOption(rawValue: eventAlert)?.title ?? "None") · Reminders: \(ReminderAlertOption(rawValue: reminderAlert)?.title ?? "None")")
                    }
                }.listRowBackground(GalleryPalette.card)
                Section("Widgets") {
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
                }.listRowBackground(GalleryPalette.card)
            }
            .listRowBackground(GalleryPalette.card)
            .navigationDestination(isPresented: $model.showingThemePicker) { appThemePicker }
            .navigationTitle("Settings")
            .galleryTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
            .toolbar { if !embedded { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } } }
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
    private func sourcePicker(reminders: Bool) -> some View {
        let sources = reminders ? model.lists : model.calendars
        let access = reminders ? model.reminderAccess : model.calendarAccess
        let accounts = Dictionary(grouping: sources, by: { $0.source.title }).sorted { $0.key < $1.key }
        return List {
            if !access {
                Section {
                    Button("Connect Apple \(reminders ? "Reminders" : "Calendar")") { Task { await model.request(reminders ? .reminder : .event) } }
                }
            } else if sources.isEmpty { ContentUnavailableView("No \(reminders ? "lists" : "calendars") yet", systemImage: reminders ? "checklist" : "calendar") }
            ForEach(accounts, id: \.key) { account, entries in
                Section(account) {
                    ForEach(entries, id: \.calendarIdentifier) { source in
                        Toggle(isOn: Binding(get: { Preferences.selected(source.calendarIdentifier, reminders: reminders) }, set: {
                            Preferences.setSelected(source.calendarIdentifier, enabled: $0, reminders: reminders, available: sources.map(\.calendarIdentifier))
                            model.objectWillChange.send()
                            model.scheduleRefresh()
                        })) {
                            HStack(spacing: 12) {
                                Circle().fill(Color(cgColor: source.cgColor)).frame(width: 10, height: 10)
                                Text(source.title)
                            }
                        }
                    }
                }
            }
            Section {
                Text(reminders ? "Selected lists appear in your agenda and widgets. Only incomplete reminders due within the displayed date range are included." : "Selected calendars appear in your agenda, calendar views, and widgets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }.navigationTitle(reminders ? "Reminder lists" : "Calendars").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
    }
    /// The app's own themes; each fixes light or dark, so the app no longer follows the device setting.
    private var appThemePicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(AppTheme.allCases) { option in
                    let c = option.colors
                    Button {
                        appThemeID = option.rawValue
                        // The default accent comes from the theme, and widgets use it too.
                        WidgetCenter.shared.reloadAllTimelines()
                        // Match the Home Screen icon. iOS confirms the change with its own short alert.
                        if UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != option.iconName {
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
            Text("Themes set the app’s colors and whether it looks light or dark. A custom App accent still overrides the theme’s accent. Widgets keep their own themes.")
                .font(.footnote).foregroundStyle(GalleryPalette.muted).padding(.horizontal).padding(.bottom)
        }
        .background(GalleryPalette.paper)
        .navigationTitle("App Theme").navigationBarTitleDisplayMode(.inline)
    }
    private var themePicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(AgendaTheme.allCases) { option in
                    Button {
                        themeID = option.rawValue
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("TODAY").font(.caption2.bold()); Spacer(); Image(systemName: "plus") }.foregroundStyle(option.secondary(colorScheme))
                            previewRow("Morning walk", color: .green, theme: option)
                            previewRow("Lunch with Sam", color: .blue, theme: option)
                            HStack { Text(option.title).font(.subheadline.bold()); Spacer(); Image(systemName: themeID == option.rawValue ? "checkmark.circle.fill" : "circle") }
                                .foregroundStyle(option.text(colorScheme))
                        }.padding(16).background { previewBackground(option, cornerRadius: 22) }
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(themeID == option.rawValue ? accent : .clear, lineWidth: 3).padding(-5) }
                    }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(themeID == option.rawValue ? .isSelected : [])
                }
            }.padding()
            customEditor
            Text("Calendar colors stay true to your sources. Preset themes adapt to light and dark; Black always stays black. Individual widgets can override this default in Edit Widget.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical)
        }
        .background(GalleryPalette.paper).navigationTitle("Widget theme").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .onChange(of: customStyle) { _, style in
            style.save()
            themeID = AgendaTheme.custom.rawValue
        }
        // Color pickers change continuously, so wait for a pause before asking widgets to redraw.
        .task(id: customStyle) {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { WidgetCenter.shared.reloadAllTimelines() }
        }
    }
    /// Preset themes are flat colors; the custom style adds a gradient and border, previewed in a rounded card.
    @ViewBuilder private func previewBackground(_ option: AgendaTheme, cornerRadius: CGFloat) -> some View {
        if option == .custom {
            customStyle.fillView.overlay {
                if customStyle.borderWidth > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(customStyle.borderColor.color, lineWidth: customStyle.borderWidth)
                }
            }
        } else if option == .charcoal {
            option.charcoalFill.overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(AgendaTheme.charcoalEdge, lineWidth: 0.5) }
        } else { option.background(colorScheme) }
    }
    private func colorBinding(_ path: WritableKeyPath<CustomWidgetStyle, StoredColor>) -> Binding<Color> {
        Binding(get: { customStyle[keyPath: path].color }, set: { customStyle[keyPath: path] = StoredColor($0) })
    }
    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CUSTOM STYLE").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 32)
            // Live preview at medium-widget proportions.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TODAY").font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(customStyle.accent.map(CustomWidgetStyle.contrastingText) ?? _accent.contrastingText)
                        .background(customStyle.accent?.color ?? accent, in: Capsule())
                    Spacer(); Image(systemName: "plus").opacity(0.65)
                }
                previewLine("Morning walk", time: "7:00–7:45 AM", color: .green)
                previewLine("Lunch with Sam", time: "12:30–1:30 PM", color: .blue)
                Spacer(minLength: 0)
            }
            .foregroundStyle(customStyle.text)
            .padding(16).frame(maxWidth: .infinity).frame(height: 150)
            .background { previewBackground(.custom, cornerRadius: 24) }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal)
            .accessibilityHidden(true)
            VStack(spacing: 0) {
                Picker("Fill", selection: $customStyle.fill) {
                    ForEach(CustomWidgetStyle.Fill.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(12)
                Divider().padding(.leading)
                ColorPicker(customStyle.fill == .solid ? "Color" : "First color", selection: colorBinding(\.first), supportsOpacity: false).padding(12)
                if customStyle.fill == .gradient {
                    Divider().padding(.leading)
                    ColorPicker("Second color", selection: colorBinding(\.second), supportsOpacity: false).padding(12)
                    Divider().padding(.leading)
                    LabeledContent("Direction") {
                        Picker("Direction", selection: $customStyle.direction) {
                            ForEach(CustomWidgetStyle.Direction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
                Divider().padding(.leading)
                Toggle("Own accent color", isOn: Binding(get: { customStyle.accent != nil }, set: { customStyle.accent = $0 ? StoredColor(accent) : nil }))
                    .padding(12)
                if customStyle.accent != nil {
                    Divider().padding(.leading)
                    ColorPicker("Accent color", selection: Binding(get: { customStyle.accent?.color ?? accent }, set: { customStyle.accent = StoredColor($0) }), supportsOpacity: false)
                        .padding(12)
                }
                Divider().padding(.leading)
                HStack {
                    Text("Border")
                    Slider(value: $customStyle.borderWidth, in: 0...6, step: 0.5)
                    Text(customStyle.borderWidth == 0 ? "None" : "\(customStyle.borderWidth.formatted()) pt").font(.footnote).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }.padding(12)
                Divider().padding(.leading)
                // Always available; picking a color with no border yet turns on a 2 pt border so the change is visible.
                ColorPicker("Border color", selection: Binding(get: { customStyle.borderColor.color }, set: {
                    customStyle.borderColor = StoredColor($0)
                    if customStyle.borderWidth == 0 { customStyle.borderWidth = 2 }
                }), supportsOpacity: true).padding(12)
            }
            .background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            Text("Editing these switches your widgets to the Custom theme. The accent colors the selected day and Next Up; without its own, widgets use the app accent. Text turns black or white to stay readable.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 32)
        }
    }
    private func previewLine(_ title: String, time: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(time).font(.caption2).opacity(0.65)
            }
        }
    }
    private func previewRow(_ title: String, color: Color, theme: AgendaTheme) -> some View {
        HStack(spacing: 6) { Capsule().fill(color).frame(width: 3, height: 16); Text(title).font(.caption).foregroundStyle(theme.text(colorScheme)).lineLimit(1) }
    }
}
