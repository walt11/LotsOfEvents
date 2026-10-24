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
    @State private var days = Preferences.days
    @AppStorage("widgetTheme", store: Preferences.defaults) private var themeID = AgendaTheme.selected.rawValue
    private var theme: AgendaTheme { AgendaTheme(rawValue: themeID) ?? .graphite }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").font(.title).foregroundStyle(_accent.contrastingText)
                            .frame(width: 56, height: 56).background(accent.gradient, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make it yours").font(.title3.bold())
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
                }
                Section("Appearance") {
                    ColorPicker(selection: $accent, supportsOpacity: false) {
                        settingsRow("App accent", symbol: "eyedropper", color: accent, detail: "Choose any color for buttons & selections")
                    }
                    Button("Reset app accent") { _accent.reset() }
                    NavigationLink {
                        themePicker
                    } label: {
                        settingsRow("Widget theme", symbol: "paintpalette", color: .purple, detail: theme.title)
                    }
                }
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
                    } label: { settingsRow("Widget guide", symbol: "square.grid.2x2", color: .indigo, detail: "Layouts, customization & Quick Add") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
                        }.padding(16).background(option.background(colorScheme), in: RoundedRectangle(cornerRadius: 22))
                            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(themeID == option.rawValue ? accent : .clear, lineWidth: 3) }
                    }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(themeID == option.rawValue ? .isSelected : [])
                }
            }.padding()
            Text("Calendar colors stay true to your sources. Themes adapt to light and dark; Black always stays black. Individual widgets can override this default.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Widget theme").navigationBarTitleDisplayMode(.inline)
    }
    private func previewRow(_ title: String, color: Color, theme: AgendaTheme) -> some View {
        HStack(spacing: 6) { Capsule().fill(color).frame(width: 3, height: 16); Text(title).font(.caption).foregroundStyle(theme.text(colorScheme)).lineLimit(1) }
    }
}
