import SwiftUI
import WidgetKit

/// Builds the Custom app theme from scratch or from another theme, with a preview, then applies it on Save.
/// Changes stay in a draft until then, because applying a theme rebuilds the whole app.
struct CustomAppThemeEditor: View {
    @State private var draft = CustomAppColors.saved
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        List {
            Section { preview }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section {
                Picker("Appearance", selection: $draft.dark) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }.pickerStyle(.segmented)
                Menu {
                    ForEach(AppTheme.allCases.filter { $0 != .custom }) { theme in
                        Button(theme.title) { draft = CustomAppColors(from: theme) }
                    }
                } label: { Label("Start From a Theme", systemImage: "square.on.square") }
            }
            Section {
                picker("Background", \.paper)
                picker("Cards", \.card)
                picker("Text", \.ink)
                picker("Secondary text", \.muted)
                picker("Lines", \.line)
                picker("Accent", \.accent)
            } footer: { contrastNote }
        }
        .listRowBackground(GalleryPalette.card)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .navigationTitle("Custom Theme").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft.save()
                    onSave()
                    dismiss()
                }
            }
        }
    }

    private func color(_ hex: UInt) -> Color { GalleryPalette.hex(hex) }
    private func picker(_ title: String, _ path: WritableKeyPath<CustomAppColors, UInt>) -> some View {
        ColorPicker(title, selection: Binding(get: { color(draft[keyPath: path]) }, set: { draft[keyPath: path] = StoredColor($0).hex }), supportsOpacity: false)
    }

    /// A small mock of the app in the draft colors: a page, a card with rows, and an accent button.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agenda").font(.system(.title3, design: .serif)).italic().foregroundStyle(color(draft.ink))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(["Team stand-up", "Lunch with Sam", "Renew passport"].enumerated()), id: \.offset) { index, title in
                    if index > 0 { Rectangle().fill(color(draft.line)).frame(height: 0.5) }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill([Color.blue, .green, .orange][index]).frame(width: 4, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(color(draft.ink))
                            Text(["9:30 AM", "12:30 PM", "Due today"][index]).font(.caption2).foregroundStyle(color(draft.muted))
                        }
                        Spacer()
                    }.padding(.vertical, 8).padding(.horizontal, 10)
                }
            }
            .background(color(draft.card), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color(draft.line), lineWidth: 0.5) }
            HStack {
                Spacer()
                Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(color(draft.onAccent))
                    .frame(width: 44, height: 44).background(color(draft.accent), in: Circle())
                Spacer()
            }
        }
        .padding(16)
        .background(color(draft.paper), in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the custom theme")
    }

    /// Warns when text would be hard to read; 4.5:1 for text, 3:1 for the accent against the page.
    @ViewBuilder private var contrastNote: some View {
        let problems = [
            CustomAppColors.contrast(draft.ink, draft.card) < 4.5 ? "text on cards" : nil,
            CustomAppColors.contrast(draft.ink, draft.paper) < 4.5 ? "text on the background" : nil,
            CustomAppColors.contrast(draft.muted, draft.card) < 4.5 ? "secondary text on cards" : nil,
            CustomAppColors.contrast(draft.accent, draft.paper) < 3 ? "the accent on the background" : nil
        ].compactMap { $0 }
        if problems.isEmpty {
            Text("Text on the accent turns black or white to stay readable.")
        } else {
            Label("Low contrast: \(problems.formatted(.list(type: .and))). Some text may be hard to read.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// Reorders the Calendar, Agenda, and Reminders tabs and picks the one the app opens to.
struct TabsSettingsView: View {
    @AppStorage(AppTabs.orderKey, store: Preferences.defaults) private var orderID = "0,1,2"
    @AppStorage(AppTabs.startKey, store: Preferences.defaults) private var start = 0
    private static let symbols = ["calendar", "list.bullet.rectangle", "checklist"]

    var body: some View {
        List {
            Section {
                Picker("Open to", selection: $start) {
                    ForEach(AppTabs.order(orderID), id: \.self) { Text(AppTabs.titles[$0]).tag($0) }
                }
            } footer: { Text("Takes effect the next time the app starts.") }
            Section {
                ForEach(AppTabs.order(orderID), id: \.self) { index in
                    Label(AppTabs.titles[index], systemImage: Self.symbols[index])
                }
                .onMove { from, to in
                    var order = AppTabs.order(orderID)
                    order.move(fromOffsets: from, toOffset: to)
                    orderID = AppTabs.stored(order)
                }
            } header: { Text("Tab order") } footer: {
                Text("Drag to reorder. Quick Add stays in the middle of the tab bar and Settings stays last.")
            }
            Section {
                Button("Reset to Default Order") { orderID = AppTabs.stored([0, 1, 2]); start = 0 }
            }
        }
        .environment(\.editMode, .constant(.active))
        .listRowBackground(GalleryPalette.card)
        .scrollContentBackground(.hidden).background(GalleryPalette.paper)
        .navigationTitle("Tabs").navigationBarTitleDisplayMode(.inline)
    }
}
