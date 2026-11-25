import SwiftUI
import Contacts
import EventKit
import WidgetKit

private actor ContactDateReader {
    func read() throws -> [ContactDateRecord] {
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactBirthdayKey as CNKeyDescriptor, CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
                    CNContactDatesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var records: [ContactDateRecord] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact"
            if let birthday = contact.birthday ?? contact.nonGregorianBirthday {
                records.append(ContactDateRecord(id: contact.identifier + ":birthday", contactID: contact.identifier,
                                                 name: name, label: "Birthday", components: birthday, birthday: true))
            }
            // A contact can have both, and people often keep both dates.
            if contact.birthday != nil, let other = contact.nonGregorianBirthday {
                let calendarName = other.calendar.flatMap { Locale.current.localizedString(for: $0.identifier) } ?? "Other Calendar"
                records.append(ContactDateRecord(id: contact.identifier + ":birthday-other", contactID: contact.identifier,
                                                 name: name, label: "Birthday (\(calendarName))", components: other, birthday: true))
            }
            for date in contact.dates {
                let label = date.label.map { CNLabeledValue<NSDateComponents>.localizedString(forLabel: $0) } ?? "Date"
                records.append(ContactDateRecord(id: contact.identifier + ":" + date.identifier, contactID: contact.identifier,
                                                 name: name, label: label, components: date.value as DateComponents, birthday: false))
            }
        }
        return records.sorted { $0.id < $1.id }
    }
}

@MainActor enum ContactDateSync {
    private static let reader = ContactDateReader()
    /// Reading every contact is slow, so it waits for a change in Contacts, or an hour as a backstop.
    private static var contactsChanged = true
    private static var lastRead = Date.distantPast
    static func markChanged() { contactsChanged = true }
    static var allowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }
    static func refresh() async throws {
        ContactDates.migrateSettings()
        guard ContactDates.enabled && allowed else { clear(); contactsChanged = true; return }
        guard contactsChanged || Date.now.timeIntervalSince(lastRead) > 3600 else { return }
        contactsChanged = false
        lastRead = .now
        let records: [ContactDateRecord]
        do { records = try await reader.read() } catch { contactsChanged = true; throw error }
        // Permission or the setting can change while the read is running.
        guard ContactDates.enabled && allowed else { clear(); return }
        let data = try JSONEncoder().encode(records)
        if Preferences.defaults.data(forKey: ContactDates.cacheKey) != data {
            Preferences.defaults.set(data, forKey: ContactDates.cacheKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    static func clear() {
        if Preferences.defaults.object(forKey: ContactDates.cacheKey) != nil {
            Preferences.defaults.removeObject(forKey: ContactDates.cacheKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct ContactDatesSettings: View {
    @ObservedObject var model: AgendaModel
    @AppStorage(ContactDates.enabledKey, store: Preferences.defaults) private var enabled = false
    @AppStorage(ContactDates.colorKey, store: Preferences.defaults) private var colorRGB = ContactDates.defaultColor
    @State private var connecting = false
    @State private var problem: String?
    var body: some View {
        Group {
            Toggle("Birthdays & Contact Dates", isOn: Binding(get: { enabled }, set: { on in
                if !on { enabled = false; ContactDateSync.clear(); model.scheduleRefresh(); return }
                connecting = true
                Task {
                    defer { connecting = false }
                    do {
                        let granted = try await CNContactStore().requestAccess(for: .contacts)
                        guard granted else { problem = "Allow Contacts access in system Settings to show contact dates."; return }
                        enabled = true
                        ContactDateSync.markChanged()
                        try await ContactDateSync.refresh()
                        model.scheduleRefresh()
                    } catch { problem = error.localizedDescription }
                }
            })).disabled(connecting)
            if connecting { ProgressView("Connecting Contacts…") }
            if enabled {
                NavigationLink("Choose Contacts & Occasions") { ContactDateSelectionView(model: model) }
                ColorPicker("Contact Dates Color", selection: Binding(
                    get: { GalleryPalette.hex(UInt(colorRGB)) },
                    set: { colorRGB = Int(StoredColor($0).hex) }
                ), supportsOpacity: false)
                .onChange(of: colorRGB) { _, _ in
                    model.scheduleRefresh()
                    WidgetReloader.schedule()
                }
                Text("\(ContactDates.records.count) dated fields available").font(.footnote).foregroundStyle(.secondary)
                if CNContactStore.authorizationStatus(for: .contacts) == .limited {
                    Text("Only contacts you have shared with LotsOfEvents are included.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("Show birthdays, anniversaries, and custom dates as yearly, all-day events in the calendar, agenda, and widgets. Includes ages and years when an original year is saved. Apple’s Birthdays calendar is hidden in LotsOfEvents while this is on; your calendar selection is restored when it is off. Edit dates in Contacts. February 29 appears on February 28 in other years. Contact dates stay on your devices.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowBackground(GalleryPalette.card)
        .alert("Contacts Access", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
}

struct ContactDateDetails: View {
    let record: ContactDateRecord
    let date: Date
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Contact", value: record.name)
                    LabeledContent("Occasion", value: record.label)
                    LabeledContent("Date", value: date.formatted(date: .complete, time: .omitted))
                    LabeledContent("Repeats", value: "Every year · All day")
                }
                Section { Text("This date comes from Contacts. To change or remove it, edit the date on the contact’s card in Contacts.") }
            }
            .navigationTitle(record.label)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(idealWidth: 520, idealHeight: 420)
    }
}

/// A compact, distinct group for personal occasions, with no repeated all-day labels.
struct CompactContactDates: View {
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let open: () -> Void
    }
    private let entries: [Entry]
    init(items: [AgendaItem], model: AgendaModel) {
        entries = items.filter { $0.contactDateID != nil }.map { item in
            Entry(id: item.id, title: item.title, symbol: item.dateSymbol ?? "calendar", open: { model.open(item) })
        }
    }
    init(events: [EKEvent], model: AgendaModel) {
        entries = events.filter { $0.contactDateID != nil }.map { event in
            Entry(id: "\(event.contactDateID ?? ""):\(event.startDate.timeIntervalSince1970)",
                  title: event.title ?? "Contact date", symbol: event.dateSymbol ?? "calendar", open: { model.inspect(event) })
        }
    }
    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    Button(action: entry.open) {
                        HStack(spacing: 8) {
                            Image(systemName: entry.symbol).foregroundStyle(ContactDates.color)
                                .frame(width: 18).accessibilityHidden(true)
                            Text(entry.title).foregroundStyle(GalleryPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows contact date details")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ContactDates.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ContactDates.color.opacity(0.22), lineWidth: 0.5) }
        }
    }
}
