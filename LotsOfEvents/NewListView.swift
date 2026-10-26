import SwiftUI
import EventKit

/// The colors Apple Reminders offers for lists, so new lists look at home there too.
enum ListColors {
    static let presets: [(name: String, color: StoredColor)] = [
        ("Red", StoredColor(red: 1.0, green: 0.23, blue: 0.19)),
        ("Orange", StoredColor(red: 1.0, green: 0.58, blue: 0.0)),
        ("Yellow", StoredColor(red: 1.0, green: 0.8, blue: 0.0)),
        ("Green", StoredColor(red: 0.2, green: 0.78, blue: 0.35)),
        ("Blue", StoredColor(red: 0.0, green: 0.48, blue: 1.0)),
        ("Purple", StoredColor(red: 0.69, green: 0.32, blue: 0.87)),
        ("Brown", StoredColor(red: 0.64, green: 0.52, blue: 0.37)),
        ("Gray", StoredColor(red: 0.56, green: 0.56, blue: 0.58))
    ]
}

extension AgendaModel {
    /// Accounts that can hold a new reminder list: those that already have a writable list.
    var listSources: [EKSource] {
        var seen = Set<String>()
        return lists.filter(\.allowsContentModifications).compactMap(\.source).filter { seen.insert($0.sourceIdentifier).inserted }
    }
    /// Creates a reminder list and returns its identifier.
    @discardableResult
    func createList(named name: String, color: StoredColor, in source: EKSource) throws -> String {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.cgColor = CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        list.source = source
        try store.saveCalendar(list, commit: true)
        lists = store.calendars(for: .reminder)
        lastCreatedListID = list.calendarIdentifier
        scheduleRefresh()
        return list.calendarIdentifier
    }
}

struct NewListView: View {
    @AppAccent private var accent
    @ObservedObject var model: AgendaModel
    /// Called with the new list's identifier after it is saved.
    var onCreate: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = ListColors.presets[4].color
    @State private var sourceID = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var source: EKSource? {
        model.listSources.first { $0.sourceIdentifier == sourceID }
            ?? model.store.defaultCalendarForNewReminders()?.source
            ?? model.listSources.first
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(color.color, in: Circle())
                            .accessibilityHidden(true)
                        TextField("List name", text: $name)
                            .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                            .padding(.vertical, 10).background(GalleryPalette.paper, in: RoundedRectangle(cornerRadius: 12))
                            .focused($nameFocused).submitLabel(.done).onSubmit(save)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(ListColors.presets, id: \.name) { preset in
                            Button { color = preset.color } label: {
                                Circle().fill(preset.color.color).frame(width: 36, height: 36)
                                    .overlay { Circle().strokeBorder(GalleryPalette.ink.opacity(color == preset.color ? 0.85 : 0), lineWidth: 3).padding(-5) }
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(color == preset.color ? .isSelected : [])
                        }
                        ColorPicker("Custom color", selection: Binding(get: { color.color }, set: { color = StoredColor($0) }), supportsOpacity: false)
                            .labelsHidden().frame(width: 44, height: 44)
                    }
                    .padding(.vertical, 4)
                }
                if model.listSources.count > 1 {
                    Section("Account") {
                        Picker("Account", selection: $sourceID) {
                            ForEach(model.listSources, id: \.sourceIdentifier) { Text($0.title).tag($0.sourceIdentifier) }
                        }
                    }
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: save).fontWeight(.semibold).disabled(trimmed.isEmpty || source == nil) }
            }
            .alert("Unable to create list", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
            .onAppear { sourceID = source?.sourceIdentifier ?? "" }
            .task {
                // Focusing during the sheet's presentation animation is ignored, so wait for it to settle.
                try? await Task.sleep(for: .milliseconds(450))
                nameFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .tint(accent)
    }
    private func save() {
        guard !trimmed.isEmpty, let source else { return }
        do {
            let id = try model.createList(named: trimmed, color: color, in: source)
            onCreate(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
